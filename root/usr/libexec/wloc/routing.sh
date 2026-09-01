#!/bin/sh
# WLOC IPv4 TPROXY policy-routing source, validation and runtime lifecycle.

ROUTING_RUNTIME_DIR=${WLOC_RUNTIME_DIR:-/var/run/wloc}
ROUTING_PERSISTENT=${WLOC_ROUTING_PATH:-/etc/wloc/routing.conf}
ROUTING_RUNTIME=${WLOC_ROUTING_RUNTIME:-${ROUTING_RUNTIME_DIR}/routing.applied.conf}
ROUTING_RUNTIME_NEXT=${WLOC_ROUTING_RUNTIME_NEXT:-${ROUTING_RUNTIME}.next}
ROUTING_LOCK=${WLOC_ROUTING_LOCK:-/var/lock/wloc-routing.lock}
ROUTING_LOCK_COMMAND=${WLOC_ROUTING_LOCK_COMMAND:-lock}
ROUTING_LOCK_TIMEOUT=${WLOC_ROUTING_LOCK_TIMEOUT:-5}
ROUTING_LOCK_HELD=0
routing_error=''

routing_set_error() {
    routing_error="$1"
}

routing_lock_release() {
    [ "${ROUTING_LOCK_HELD:-0}" -eq 1 ] || return 0
    "$ROUTING_LOCK_COMMAND" -u "$ROUTING_LOCK" >/dev/null 2>&1 || true
    ROUTING_LOCK_HELD=0
}

routing_lock_acquire() {
    local lock_parent timeout attempt
    [ "${ROUTING_LOCK_HELD:-0}" -eq 1 ] && return 0
    routing_error=''
    command -v "$ROUTING_LOCK_COMMAND" >/dev/null 2>&1 || {
        routing_set_error 'OpenWrt lock utility is not available'
        return 1
    }
    lock_parent="${ROUTING_LOCK%/*}"
    [ "$lock_parent" = "$ROUTING_LOCK" ] && lock_parent='.'
    mkdir -p "$lock_parent" || {
        routing_set_error 'unable to create the routing lock parent directory'
        return 1
    }
    timeout="$ROUTING_LOCK_TIMEOUT"
    case "$timeout" in ''|*[!0-9]*) timeout=5;; esac
    attempt=0
    while ! "$ROUTING_LOCK_COMMAND" -n "$ROUTING_LOCK" >/dev/null 2>&1; do
        if [ "$attempt" -ge "$timeout" ]; then
            routing_set_error 'Another routing operation is already in progress. Please retry.'
            return 1
        fi
        sleep 1 || {
            routing_set_error 'Another routing operation is already in progress. Please retry.'
            return 1
        }
        attempt=$((attempt + 1))
    done
    ROUTING_LOCK_HELD=1
}

routing_write_atomic() {
    local content="$1" destination="$2" directory temporary
    directory="${destination%/*}"
    [ "$directory" = "$destination" ] && directory='.'
    mkdir -p "$directory" || {
        routing_set_error 'unable to create the routing configuration directory'
        return 1
    }
    temporary="$(mktemp "${destination}.XXXXXX")" || {
        routing_set_error 'unable to create a temporary routing file'
        return 1
    }
    if ! printf '%s\n' "$content" >"$temporary" || ! chmod 0600 "$temporary"; then
        rm -f "$temporary"
        routing_set_error 'unable to write the routing configuration'
        return 1
    fi
    if ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        routing_set_error 'unable to atomically replace the routing configuration'
        return 1
    fi
}

routing_decimal_normalize() {
    local value="$1" normalized
    case "$value" in ''|*[!0-9]*) return 1;; esac
    normalized="$(printf '%s\n' "$value" | sed 's/^0*//')"
    [ -n "$normalized" ] || normalized=0
    awk -v value="$normalized" 'BEGIN { exit !(value >= 1 && value <= 4294967295) }' || return 1
    printf '%s\n' "$normalized"
}

routing_hex_normalize() {
    local value="$1" digits
    case "$value" in
        0x*|0X*) digits="${value#0x}"; digits="${digits#0X}";;
        *) return 1;;
    esac
    printf '%s\n' "$digits" | grep -Eq '^[0-9A-Fa-f]{1,8}$' || return 1
    digits="$(printf '%s' "$digits" | tr 'A-F' 'a-f')"
    while [ "${#digits}" -gt 1 ] && [ "${digits#0}" != "$digits" ]; do
        digits="${digits#0}"
    done
    printf '%s\n' "$digits" | grep -Eq '^0+$' && return 1
    printf '0x%s\n' "$digits"
}

routing_ipv4_prefix_valid() {
    printf '%s\n' "$1" | awk -F '[./]' '
        NF == 5 {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
            if ($5 !~ /^[0-9]+$/ || $5 < 0 || $5 > 32) exit 1
            exit 0
        }
        { exit 1 }
    '
}

routing_parse_file() {
    local source="$1" line value route_seen=0 rule_seen=0
    local route_prefix='' route_table='' rule_priority='' mark_mask='' rule_table=''
    local mark_literal mask_literal normalized_table normalized_priority

    routing_error=''
    ROUTING_NORMALIZED=''
    ROUTING_PREFIX=''
    ROUTING_TABLE=''
    ROUTING_PRIORITY=''
    ROUTING_MARK=''
    ROUTING_MASK=''

    [ -r "$source" ] || {
        routing_set_error "cannot read $source"
        return 1
    }
    [ "$(wc -c <"$source" 2>/dev/null || echo 0)" -le 32768 ] || {
        routing_set_error 'routing file is larger than 32 KiB'
        return 1
    }

    while IFS= read -r line || [ -n "$line" ]; do
        value="$(printf '%s\n' "$line" | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$value" ] || continue
        case "$value" in \#*) continue;; esac

        if printf '%s\n' "$value" | grep -Eq '^ip -4 route replace local [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+ dev lo table [0-9]+$'; then
            [ "$route_seen" -eq 0 ] || {
                routing_set_error 'routing file declares more than one IPv4 local route command'
                return 1
            }
            set -- $value
            route_prefix="$6"
            route_table="${10}"
            routing_ipv4_prefix_valid "$route_prefix" || {
                routing_set_error 'invalid IPv4 local route prefix'
                return 1
            }
            route_seen=1
            continue
        fi

        if printf '%s\n' "$value" | grep -Eq '^ip -4 rule add priority [0-9]+ fwmark 0[xX][0-9A-Fa-f]{1,8}/0[xX][0-9A-Fa-f]{1,8} lookup [0-9]+$'; then
            [ "$rule_seen" -eq 0 ] || {
                routing_set_error 'routing file declares more than one IPv4 fwmark rule command'
                return 1
            }
            set -- $value
            rule_priority="$6"
            mark_mask="$8"
            rule_table="${10}"
            rule_seen=1
            continue
        fi

        routing_set_error "unsupported routing command: $value"
        return 1
    done <"$source"

    [ "$route_seen" -eq 1 ] && [ "$rule_seen" -eq 1 ] || {
        routing_set_error 'routing file must declare one IPv4 local route and one IPv4 fwmark rule'
        return 1
    }

    normalized_table="$(routing_decimal_normalize "$route_table")" || {
        routing_set_error 'routing table is outside 1..4294967295'
        return 1
    }
    rule_table="$(routing_decimal_normalize "$rule_table")" || {
        routing_set_error 'routing table is outside 1..4294967295'
        return 1
    }
    [ "$normalized_table" = "$rule_table" ] || {
        routing_set_error 'IPv4 route and rule must use the same routing table'
        return 1
    }
    normalized_priority="$(routing_decimal_normalize "$rule_priority")" || {
        routing_set_error 'routing rule priority is outside 1..4294967295'
        return 1
    }

    mark_literal="${mark_mask%/*}"
    mask_literal="${mark_mask#*/}"
    mark_literal="$(routing_hex_normalize "$mark_literal")" || {
        routing_set_error 'fwmark must be a non-zero hexadecimal value up to 32 bits'
        return 1
    }
    mask_literal="$(routing_hex_normalize "$mask_literal")" || {
        routing_set_error 'fwmark mask must be a non-zero hexadecimal value up to 32 bits'
        return 1
    }

    ROUTING_PREFIX="$route_prefix"
    ROUTING_TABLE="$normalized_table"
    ROUTING_PRIORITY="$normalized_priority"
    ROUTING_MARK="$mark_literal"
    ROUTING_MASK="$mask_literal"
    ROUTING_NORMALIZED="ip -4 route replace local $ROUTING_PREFIX dev lo table $ROUTING_TABLE
ip -4 rule add priority $ROUTING_PRIORITY fwmark $ROUTING_MARK/$ROUTING_MASK lookup $ROUTING_TABLE"
}

routing_rule_present() {
    local priority="$1" mark="$2" mask="$3" table_id="$4" output
    output="$(ip -4 rule show 2>/dev/null)" || return 1
    printf '%s\n' "$output" | awk -v priority="${priority}:" -v mark="$mark" -v mask="$mask" -v table_id="$table_id" '
        $1 == priority {
            normal = "fwmark " mark "/" mask
            fullmask = "fwmark " mark
            table = "lookup " table_id
            if (index($0, table) && (index($0, normal) || (mask == "0xffffffff" && index($0, fullmask)))) {
                found = 1
                exit
            }
        }
        END { exit !found }
    '
}

routing_route_present() {
    local prefix="$1" table_id="$2" output
    output="$(ip -4 route show table "$table_id" 2>/dev/null)" || return 1
    printf '%s\n' "$output" | awk -v prefix="$prefix" '
        $1 == "local" && index($0, " dev lo") {
            if ($2 == prefix || (prefix == "0.0.0.0/0" && $2 == "default")) {
                found = 1
                exit
            }
        }
        END { exit !found }
    '
}

routing_apply_spec() {
    local prefix="$1" table_id="$2" priority="$3" mark="$4" mask="$5"
    command -v ip >/dev/null 2>&1 || {
        routing_set_error 'ip-full is required for transparent proxy routing'
        return 1
    }
    ip -4 route replace local "$prefix" dev lo table "$table_id" >/dev/null 2>&1 || {
        routing_set_error 'unable to install the IPv4 TPROXY local route'
        return 1
    }
    if ! routing_rule_present "$priority" "$mark" "$mask" "$table_id"; then
        ip -4 rule add priority "$priority" fwmark "$mark/$mask" lookup "$table_id" >/dev/null 2>&1 || {
            routing_set_error 'unable to install the IPv4 TPROXY policy rule'
            return 1
        }
    fi
    routing_route_present "$prefix" "$table_id" && \
        routing_rule_present "$priority" "$mark" "$mask" "$table_id" || {
        routing_set_error 'IPv4 TPROXY policy routing verification failed'
        return 1
    }
}

routing_remove_spec() {
    local prefix="$1" table_id="$2" priority="$3" mark="$4" mask="$5"
    while routing_rule_present "$priority" "$mark" "$mask" "$table_id"; do
        ip -4 rule del priority "$priority" fwmark "$mark/$mask" lookup "$table_id" >/dev/null 2>&1 || break
    done
    ip -4 route del local "$prefix" dev lo table "$table_id" >/dev/null 2>&1 || true
    return 0
}

routing_spec_equal() {
    [ "$1" = "$6" ] && [ "$2" = "$7" ] && [ "$3" = "$8" ] && [ "$4" = "$9" ] && [ "$5" = "${10}" ]
}

routing_apply_file() {
    local source="$1" locked_here=0 rc=1
    local new_prefix new_table new_priority new_mark new_mask new_normalized
    local old_valid=0 old_prefix old_table old_priority old_mark old_mask changed=1
    local apply_error rollback_error=''

    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then
        routing_lock_acquire || return 1
        locked_here=1
    fi

    if routing_parse_file "$source"; then
        new_prefix="$ROUTING_PREFIX"
        new_table="$ROUTING_TABLE"
        new_priority="$ROUTING_PRIORITY"
        new_mark="$ROUTING_MARK"
        new_mask="$ROUTING_MASK"
        new_normalized="$ROUTING_NORMALIZED"

        if routing_write_atomic "$new_normalized" "$ROUTING_RUNTIME_NEXT"; then
            if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then
                old_valid=1
                old_prefix="$ROUTING_PREFIX"
                old_table="$ROUTING_TABLE"
                old_priority="$ROUTING_PRIORITY"
                old_mark="$ROUTING_MARK"
                old_mask="$ROUTING_MASK"
                if routing_spec_equal "$old_prefix" "$old_table" "$old_priority" "$old_mark" "$old_mask" \
                    "$new_prefix" "$new_table" "$new_priority" "$new_mark" "$new_mask"; then
                    changed=0
                fi
            fi

            if [ "$old_valid" -eq 1 ] && [ "$changed" -eq 1 ]; then
                routing_remove_spec "$old_prefix" "$old_table" "$old_priority" "$old_mark" "$old_mask"
            fi

            if routing_apply_spec "$new_prefix" "$new_table" "$new_priority" "$new_mark" "$new_mask"; then
                if mv -f "$ROUTING_RUNTIME_NEXT" "$ROUTING_RUNTIME"; then
                    routing_error=''
                    rc=0
                else
                    routing_set_error 'unable to promote the applied routing snapshot'
                    if [ "$changed" -eq 1 ]; then
                        routing_remove_spec "$new_prefix" "$new_table" "$new_priority" "$new_mark" "$new_mask"
                        if [ "$old_valid" -eq 1 ]; then
                            routing_apply_spec "$old_prefix" "$old_table" "$old_priority" "$old_mark" "$old_mask" || \
                                rollback_error="$routing_error"
                        fi
                    fi
                    [ -z "$rollback_error" ] || routing_error="$routing_error; rollback failed: $rollback_error"
                fi
            else
                apply_error="$routing_error"
                if [ "$changed" -eq 1 ]; then
                    routing_remove_spec "$new_prefix" "$new_table" "$new_priority" "$new_mark" "$new_mask"
                    if [ "$old_valid" -eq 1 ]; then
                        routing_apply_spec "$old_prefix" "$old_table" "$old_priority" "$old_mark" "$old_mask" || \
                            rollback_error="$routing_error"
                    fi
                fi
                routing_error="$apply_error"
                [ -z "$rollback_error" ] || routing_error="$routing_error; rollback failed: $rollback_error"
                rm -f "$ROUTING_RUNTIME_NEXT"
            fi
        fi
    fi

    [ "$rc" -eq 0 ] || rm -f "$ROUTING_RUNTIME_NEXT"
    if [ "$locked_here" -eq 1 ]; then
        routing_lock_release
    fi
    return "$rc"
}

routing_save_file() {
    local source="$1" locked_here=0 rc=1 normalized
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then
        routing_lock_acquire || return 1
        locked_here=1
    fi
    if routing_parse_file "$source"; then
        normalized="$ROUTING_NORMALIZED"
        if routing_write_atomic "$normalized" "$ROUTING_PERSISTENT"; then
            routing_error=''
            rc=0
        fi
    fi
    if [ "$locked_here" -eq 1 ]; then
        routing_lock_release
    fi
    return "$rc"
}

routing_ensure_current() {
    local locked_here=0 rc=1 source_is_runtime=0
    local prefix table_id priority mark mask normalized
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then
        routing_lock_acquire || return 1
        locked_here=1
    fi

    if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then
        source_is_runtime=1
    else
        rm -f "$ROUTING_RUNTIME" >/dev/null 2>&1 || true
        routing_parse_file "$ROUTING_PERSISTENT" || {
            rc=1
            if [ "$locked_here" -eq 1 ]; then routing_lock_release; fi
            return "$rc"
        }
    fi

    prefix="$ROUTING_PREFIX"
    table_id="$ROUTING_TABLE"
    priority="$ROUTING_PRIORITY"
    mark="$ROUTING_MARK"
    mask="$ROUTING_MASK"
    normalized="$ROUTING_NORMALIZED"

    if routing_apply_spec "$prefix" "$table_id" "$priority" "$mark" "$mask"; then
        if [ "$source_is_runtime" -eq 1 ] || routing_write_atomic "$normalized" "$ROUTING_RUNTIME"; then
            routing_error=''
            rc=0
        else
            routing_remove_spec "$prefix" "$table_id" "$priority" "$mark" "$mask"
        fi
    fi

    if [ "$locked_here" -eq 1 ]; then routing_lock_release; fi
    return "$rc"
}

routing_deactivate_locked() {
    local prefix table_id priority mark mask
    if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then
        :
    elif routing_parse_file "$ROUTING_PERSISTENT"; then
        :
    else
        return 1
    fi
    prefix="$ROUTING_PREFIX"
    table_id="$ROUTING_TABLE"
    priority="$ROUTING_PRIORITY"
    mark="$ROUTING_MARK"
    mask="$ROUTING_MASK"
    routing_remove_spec "$prefix" "$table_id" "$priority" "$mark" "$mask"
    routing_error=''
}

routing_deactivate() {
    local locked_here=0 rc
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then
        routing_lock_acquire || return 1
        locked_here=1
    fi
    if routing_deactivate_locked; then rc=0; else rc=$?; fi
    if [ "$locked_here" -eq 1 ]; then routing_lock_release; fi
    return "$rc"
}

routing_reset() {
    local locked_here=0 rc=0
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then
        routing_lock_acquire || return 1
        locked_here=1
    fi
    routing_deactivate_locked || rc=1
    rm -f "$ROUTING_RUNTIME" "$ROUTING_RUNTIME_NEXT" || rc=1
    if [ "$locked_here" -eq 1 ]; then routing_lock_release; fi
    return "$rc"
}

routing_collect_active() {
    local locked_here=0 rc=1 rule_output route_output
    local prefix table_id priority mark mask
    ROUTING_ACTIVE=0
    ROUTING_ACTIVE_TEXT=''
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then
        routing_lock_acquire || return 1
        locked_here=1
    fi

    if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then
        :
    elif routing_parse_file "$ROUTING_PERSISTENT"; then
        :
    else
        if [ "$locked_here" -eq 1 ]; then routing_lock_release; fi
        return 1
    fi

    prefix="$ROUTING_PREFIX"
    table_id="$ROUTING_TABLE"
    priority="$ROUTING_PRIORITY"
    mark="$ROUTING_MARK"
    mask="$ROUTING_MASK"
    rule_output="$(ip -4 rule show 2>&1)" || rule_output='unable to read IPv4 policy rules'
    route_output="$(ip -4 route show table "$table_id" 2>&1)" || route_output='unable to read the configured IPv4 routing table'
    ROUTING_ACTIVE_TEXT="# ip -4 rule show
$rule_output

# ip -4 route show table $table_id
$route_output"
    if routing_route_present "$prefix" "$table_id" && \
        routing_rule_present "$priority" "$mark" "$mask" "$table_id"; then
        ROUTING_ACTIVE=1
    fi
    routing_error=''
    rc=0
    if [ "$locked_here" -eq 1 ]; then routing_lock_release; fi
    return "$rc"
}

if [ "${WLOC_ROUTING_HELPER_SOURCE:-0}" -ne 1 ]; then
    case "${1:-}" in
        validate)
            routing_parse_file "${2:-}" || {
                printf '%s\n' "${routing_error:-invalid routing configuration}" >&2
                exit 1
            }
            printf '%s\n' "$ROUTING_NORMALIZED"
            ;;
        apply)
            routing_apply_file "${2:-}" || {
                printf '%s\n' "${routing_error:-unable to apply routing configuration}" >&2
                exit 1
            }
            routing_collect_active || exit 1
            printf '%s\n' "$ROUTING_ACTIVE_TEXT"
            ;;
        save)
            routing_save_file "${2:-}" || {
                printf '%s\n' "${routing_error:-unable to save routing configuration}" >&2
                exit 1
            }
            printf '%s\n' "$ROUTING_NORMALIZED"
            ;;
        active)
            routing_collect_active || {
                printf '%s\n' "${routing_error:-unable to inspect routing configuration}" >&2
                exit 1
            }
            printf '%s\n' "$ROUTING_ACTIVE_TEXT"
            ;;
        ready)
            routing_collect_active >/dev/null 2>&1 && [ "$ROUTING_ACTIVE" -eq 1 ]
            ;;
        reset)
            routing_reset || {
                printf '%s\n' "${routing_error:-unable to reset routing configuration}" >&2
                exit 1
            }
            ;;
        *)
            printf '%s\n' 'usage: routing.sh {validate|apply|save} FILE | {active|ready|reset}' >&2
            exit 2
            ;;
    esac
fi
