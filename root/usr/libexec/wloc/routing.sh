#!/bin/sh
# WLOC IPv4/IPv6 TPROXY policy-routing source, validation and runtime lifecycle.

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

routing_ipv6_prefix_valid() {
    local value="$1" address prefix
    address="${value%/*}"
    prefix="${value##*/}"
    [ "$address" != "$value" ] || return 1
    printf '%s\n' "$address" | grep -Eq '^[0-9A-Fa-f:]+$' || return 1
    case "$address" in *:*) ;; *) return 1;; esac
    case "$prefix" in ''|*[!0-9]*) return 1;; esac
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ]
}

routing_normalize_spec() {
    local family="$1" prefix="$2" route_table="$3" priority="$4" mark_mask="$5" rule_table="$6"
    local table normalized_priority mark_literal mask_literal
    table="$(routing_decimal_normalize "$route_table")" || {
        routing_set_error "IPv${family} routing table is outside 1..4294967295"
        return 1
    }
    rule_table="$(routing_decimal_normalize "$rule_table")" || {
        routing_set_error "IPv${family} routing table is outside 1..4294967295"
        return 1
    }
    [ "$table" = "$rule_table" ] || {
        routing_set_error "IPv${family} route and rule must use the same routing table"
        return 1
    }
    normalized_priority="$(routing_decimal_normalize "$priority")" || {
        routing_set_error "IPv${family} routing rule priority is outside 1..4294967295"
        return 1
    }
    mark_literal="${mark_mask%/*}"
    mask_literal="${mark_mask#*/}"
    mark_literal="$(routing_hex_normalize "$mark_literal")" || {
        routing_set_error "IPv${family} fwmark must be a non-zero hexadecimal value up to 32 bits"
        return 1
    }
    mask_literal="$(routing_hex_normalize "$mask_literal")" || {
        routing_set_error "IPv${family} fwmark mask must be a non-zero hexadecimal value up to 32 bits"
        return 1
    }
    SPEC_PREFIX="$prefix"
    SPEC_TABLE="$table"
    SPEC_PRIORITY="$normalized_priority"
    SPEC_MARK="$mark_literal"
    SPEC_MASK="$mask_literal"
}

routing_parse_file() {
    local source="$1" line value
    local v4_route_seen=0 v4_rule_seen=0 v6_route_seen=0 v6_rule_seen=0
    local v4_prefix='' v4_route_table='' v4_priority='' v4_mark_mask='' v4_rule_table=''
    local v6_prefix='' v6_route_table='' v6_priority='' v6_mark_mask='' v6_rule_table=''

    routing_error=''
    ROUTING_NORMALIZED=''
    ROUTING_IPV6_ENABLED=0
    ROUTING_V4_PREFIX='' ROUTING_V4_TABLE='' ROUTING_V4_PRIORITY='' ROUTING_V4_MARK='' ROUTING_V4_MASK=''
    ROUTING_V6_PREFIX='' ROUTING_V6_TABLE='' ROUTING_V6_PRIORITY='' ROUTING_V6_MARK='' ROUTING_V6_MASK=''

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
            [ "$v4_route_seen" -eq 0 ] || { routing_set_error 'routing file declares more than one IPv4 local route command'; return 1; }
            set -- $value
            v4_prefix="$6"; v4_route_table="${10}"
            routing_ipv4_prefix_valid "$v4_prefix" || { routing_set_error 'invalid IPv4 local route prefix'; return 1; }
            v4_route_seen=1
            continue
        fi
        if printf '%s\n' "$value" | grep -Eq '^ip -4 rule add priority [0-9]+ fwmark 0[xX][0-9A-Fa-f]{1,8}/0[xX][0-9A-Fa-f]{1,8} lookup [0-9]+$'; then
            [ "$v4_rule_seen" -eq 0 ] || { routing_set_error 'routing file declares more than one IPv4 fwmark rule command'; return 1; }
            set -- $value
            v4_priority="$6"; v4_mark_mask="$8"; v4_rule_table="${10}"
            v4_rule_seen=1
            continue
        fi
        if printf '%s\n' "$value" | grep -Eq '^ip -6 route replace local [0-9A-Fa-f:]+/[0-9]+ dev lo table [0-9]+$'; then
            [ "$v6_route_seen" -eq 0 ] || { routing_set_error 'routing file declares more than one IPv6 local route command'; return 1; }
            set -- $value
            v6_prefix="$6"; v6_route_table="${10}"
            routing_ipv6_prefix_valid "$v6_prefix" || { routing_set_error 'invalid IPv6 local route prefix'; return 1; }
            v6_route_seen=1
            continue
        fi
        if printf '%s\n' "$value" | grep -Eq '^ip -6 rule add priority [0-9]+ fwmark 0[xX][0-9A-Fa-f]{1,8}/0[xX][0-9A-Fa-f]{1,8} lookup [0-9]+$'; then
            [ "$v6_rule_seen" -eq 0 ] || { routing_set_error 'routing file declares more than one IPv6 fwmark rule command'; return 1; }
            set -- $value
            v6_priority="$6"; v6_mark_mask="$8"; v6_rule_table="${10}"
            v6_rule_seen=1
            continue
        fi
        routing_set_error "unsupported routing command: $value"
        return 1
    done <"$source"

    [ "$v4_route_seen" -eq 1 ] && [ "$v4_rule_seen" -eq 1 ] || {
        routing_set_error 'routing file must declare one IPv4 local route and one IPv4 fwmark rule'
        return 1
    }
    [ "$v6_route_seen" -eq "$v6_rule_seen" ] || {
        routing_set_error 'routing file must declare both IPv6 route and rule commands'
        return 1
    }

    routing_normalize_spec 4 "$v4_prefix" "$v4_route_table" "$v4_priority" "$v4_mark_mask" "$v4_rule_table" || return 1
    ROUTING_V4_PREFIX="$SPEC_PREFIX"; ROUTING_V4_TABLE="$SPEC_TABLE"; ROUTING_V4_PRIORITY="$SPEC_PRIORITY"; ROUTING_V4_MARK="$SPEC_MARK"; ROUTING_V4_MASK="$SPEC_MASK"
    ROUTING_NORMALIZED="ip -4 route replace local $ROUTING_V4_PREFIX dev lo table $ROUTING_V4_TABLE
ip -4 rule add priority $ROUTING_V4_PRIORITY fwmark $ROUTING_V4_MARK/$ROUTING_V4_MASK lookup $ROUTING_V4_TABLE"

    if [ "$v6_route_seen" -eq 1 ]; then
        routing_normalize_spec 6 "$v6_prefix" "$v6_route_table" "$v6_priority" "$v6_mark_mask" "$v6_rule_table" || return 1
        ROUTING_V6_PREFIX="$SPEC_PREFIX"; ROUTING_V6_TABLE="$SPEC_TABLE"; ROUTING_V6_PRIORITY="$SPEC_PRIORITY"; ROUTING_V6_MARK="$SPEC_MARK"; ROUTING_V6_MASK="$SPEC_MASK"
        ROUTING_IPV6_ENABLED=1
        ROUTING_NORMALIZED="$ROUTING_NORMALIZED
ip -6 route replace local $ROUTING_V6_PREFIX dev lo table $ROUTING_V6_TABLE
ip -6 rule add priority $ROUTING_V6_PRIORITY fwmark $ROUTING_V6_MARK/$ROUTING_V6_MASK lookup $ROUTING_V6_TABLE"
    fi
}

routing_rule_present() {
    local family="$1" priority="$2" mark="$3" mask="$4" table_id="$5" output
    output="$(ip -"$family" rule show 2>/dev/null)" || return 1
    printf '%s\n' "$output" | awk -v priority="${priority}:" -v mark="$mark" -v mask="$mask" -v table_id="$table_id" '
        $1 == priority {
            normal = "fwmark " mark "/" mask
            fullmask = "fwmark " mark
            table = "lookup " table_id
            if (index($0, table) && (index($0, normal) || (mask == "0xffffffff" && index($0, fullmask)))) { found = 1; exit }
        }
        END { exit !found }
    '
}

routing_route_present() {
    local family="$1" prefix="$2" table_id="$3" output
    output="$(ip -"$family" route show table "$table_id" 2>/dev/null)" || return 1
    printf '%s\n' "$output" | awk -v prefix="$prefix" '
        $1 == "local" && index($0, " dev lo") {
            if ($2 == prefix || ((prefix == "0.0.0.0/0" || prefix == "::/0") && $2 == "default")) { found = 1; exit }
        }
        END { exit !found }
    '
}

routing_remove_family() {
    local family="$1" prefix="$2" table_id="$3" priority="$4" mark="$5" mask="$6"
    while routing_rule_present "$family" "$priority" "$mark" "$mask" "$table_id"; do
        ip -"$family" rule del priority "$priority" fwmark "$mark/$mask" lookup "$table_id" >/dev/null 2>&1 || break
    done
    ip -"$family" route del local "$prefix" dev lo table "$table_id" >/dev/null 2>&1 || true
}

routing_apply_family() {
    local family="$1" prefix="$2" table_id="$3" priority="$4" mark="$5" mask="$6"
    command -v ip >/dev/null 2>&1 || { routing_set_error 'ip-full is required for transparent proxy routing'; return 1; }
    ip -"$family" route replace local "$prefix" dev lo table "$table_id" >/dev/null 2>&1 || {
        routing_set_error "unable to install the IPv${family} TPROXY local route"
        return 1
    }
    if ! routing_rule_present "$family" "$priority" "$mark" "$mask" "$table_id"; then
        ip -"$family" rule add priority "$priority" fwmark "$mark/$mask" lookup "$table_id" >/dev/null 2>&1 || {
            ip -"$family" route del local "$prefix" dev lo table "$table_id" >/dev/null 2>&1 || true
            routing_set_error "unable to install the IPv${family} TPROXY policy rule"
            return 1
        }
    fi
    routing_route_present "$family" "$prefix" "$table_id" && routing_rule_present "$family" "$priority" "$mark" "$mask" "$table_id" || {
        routing_remove_family "$family" "$prefix" "$table_id" "$priority" "$mark" "$mask"
        routing_set_error "IPv${family} TPROXY policy routing verification failed"
        return 1
    }
}

routing_apply_current() {
    routing_apply_family 4 "$ROUTING_V4_PREFIX" "$ROUTING_V4_TABLE" "$ROUTING_V4_PRIORITY" "$ROUTING_V4_MARK" "$ROUTING_V4_MASK" || return 1
    if [ "$ROUTING_IPV6_ENABLED" -eq 1 ]; then
        routing_apply_family 6 "$ROUTING_V6_PREFIX" "$ROUTING_V6_TABLE" "$ROUTING_V6_PRIORITY" "$ROUTING_V6_MARK" "$ROUTING_V6_MASK" || {
            local error="$routing_error"
            routing_remove_family 4 "$ROUTING_V4_PREFIX" "$ROUTING_V4_TABLE" "$ROUTING_V4_PRIORITY" "$ROUTING_V4_MARK" "$ROUTING_V4_MASK"
            routing_error="$error"
            return 1
        }
    fi
}

routing_remove_current() {
    [ "$ROUTING_IPV6_ENABLED" -eq 1 ] && routing_remove_family 6 "$ROUTING_V6_PREFIX" "$ROUTING_V6_TABLE" "$ROUTING_V6_PRIORITY" "$ROUTING_V6_MARK" "$ROUTING_V6_MASK"
    routing_remove_family 4 "$ROUTING_V4_PREFIX" "$ROUTING_V4_TABLE" "$ROUTING_V4_PRIORITY" "$ROUTING_V4_MARK" "$ROUTING_V4_MASK"
}

routing_apply_file() {
    local source="$1" locked_here=0 rc=1 old_snapshot='' new_snapshot='' rollback_file
    local old_valid=0 changed=1 apply_error='' rollback_error=''
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then routing_lock_acquire || return 1; locked_here=1; fi
    if routing_parse_file "$source"; then
        new_snapshot="$ROUTING_NORMALIZED"
        if routing_write_atomic "$new_snapshot" "$ROUTING_RUNTIME_NEXT"; then
            if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then
                old_valid=1
                old_snapshot="$ROUTING_NORMALIZED"
                [ "$old_snapshot" = "$new_snapshot" ] && changed=0
            fi
            if [ "$old_valid" -eq 1 ] && [ "$changed" -eq 1 ]; then
                routing_remove_current
            fi
            if routing_parse_file "$ROUTING_RUNTIME_NEXT" && routing_apply_current; then
                if mv -f "$ROUTING_RUNTIME_NEXT" "$ROUTING_RUNTIME"; then
                    routing_error=''
                    rc=0
                else
                    apply_error='unable to promote the applied routing snapshot'
                fi
            else
                apply_error="$routing_error"
            fi
            if [ "$rc" -ne 0 ] && [ "$changed" -eq 1 ]; then
                if routing_parse_file "$ROUTING_RUNTIME_NEXT"; then
                    routing_remove_current
                fi
                if [ "$old_valid" -eq 1 ]; then
                    rollback_file="${ROUTING_RUNTIME}.rollback.$$"
                    if routing_write_atomic "$old_snapshot" "$rollback_file" && routing_parse_file "$rollback_file"; then
                        routing_apply_current || rollback_error="$routing_error"
                    fi
                    rm -f "$rollback_file"
                fi
            fi
            if [ "$rc" -ne 0 ]; then
                routing_error="$apply_error"
                [ -z "$rollback_error" ] || routing_error="$routing_error; rollback failed: $rollback_error"
            fi
        fi
    fi
    [ "$rc" -eq 0 ] || rm -f "$ROUTING_RUNTIME_NEXT"
    [ "$locked_here" -eq 0 ] || routing_lock_release
    return "$rc"
}

routing_save_file() {
    local source="$1" locked_here=0 rc=1 normalized
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then routing_lock_acquire || return 1; locked_here=1; fi
    if routing_parse_file "$source"; then
        normalized="$ROUTING_NORMALIZED"
        if routing_write_atomic "$normalized" "$ROUTING_PERSISTENT"; then routing_error=''; rc=0; fi
    fi
    [ "$locked_here" -eq 0 ] || routing_lock_release
    return "$rc"
}

routing_ensure_current() {
    local locked_here=0 rc=1 source_is_runtime=0 normalized
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then routing_lock_acquire || return 1; locked_here=1; fi
    if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then
        source_is_runtime=1
    else
        rm -f "$ROUTING_RUNTIME" >/dev/null 2>&1 || true
        routing_parse_file "$ROUTING_PERSISTENT" || { [ "$locked_here" -eq 0 ] || routing_lock_release; return 1; }
    fi
    normalized="$ROUTING_NORMALIZED"
    if routing_apply_current; then
        if [ "$source_is_runtime" -eq 1 ] || routing_write_atomic "$normalized" "$ROUTING_RUNTIME"; then routing_error=''; rc=0; else routing_remove_current; fi
    fi
    [ "$locked_here" -eq 0 ] || routing_lock_release
    return "$rc"
}

routing_deactivate_locked() {
    if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then :
    elif routing_parse_file "$ROUTING_PERSISTENT"; then :
    else return 1; fi
    routing_remove_current
    routing_error=''
}

routing_deactivate() {
    local locked_here=0 rc
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then routing_lock_acquire || return 1; locked_here=1; fi
    if routing_deactivate_locked; then rc=0; else rc=$?; fi
    [ "$locked_here" -eq 0 ] || routing_lock_release
    return "$rc"
}

routing_reset() {
    local locked_here=0 rc=0
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then routing_lock_acquire || return 1; locked_here=1; fi
    routing_deactivate_locked || rc=1
    rm -f "$ROUTING_RUNTIME" "$ROUTING_RUNTIME_NEXT" || rc=1
    [ "$locked_here" -eq 0 ] || routing_lock_release
    return "$rc"
}

routing_collect_active() {
    local locked_here=0 rc=1 v4_rules v4_routes v6_rules='' v6_routes=''
    ROUTING_ACTIVE=0
    ROUTING_ACTIVE_TEXT=''
    if [ "${ROUTING_LOCK_HELD:-0}" -ne 1 ]; then routing_lock_acquire || return 1; locked_here=1; fi
    if [ -r "$ROUTING_RUNTIME" ] && routing_parse_file "$ROUTING_RUNTIME"; then :
    elif routing_parse_file "$ROUTING_PERSISTENT"; then :
    else [ "$locked_here" -eq 0 ] || routing_lock_release; return 1; fi
    v4_rules="$(ip -4 rule show 2>&1)" || v4_rules='unable to read IPv4 policy rules'
    v4_routes="$(ip -4 route show table "$ROUTING_V4_TABLE" 2>&1)" || v4_routes='unable to read the configured IPv4 routing table'
    ROUTING_ACTIVE_TEXT="# ip -4 rule show
$v4_rules

# ip -4 route show table $ROUTING_V4_TABLE
$v4_routes"
    if routing_route_present 4 "$ROUTING_V4_PREFIX" "$ROUTING_V4_TABLE" && routing_rule_present 4 "$ROUTING_V4_PRIORITY" "$ROUTING_V4_MARK" "$ROUTING_V4_MASK" "$ROUTING_V4_TABLE"; then
        ROUTING_ACTIVE=1
    fi
    if [ "$ROUTING_IPV6_ENABLED" -eq 1 ]; then
        v6_rules="$(ip -6 rule show 2>&1)" || v6_rules='unable to read IPv6 policy rules'
        v6_routes="$(ip -6 route show table "$ROUTING_V6_TABLE" 2>&1)" || v6_routes='unable to read the configured IPv6 routing table'
        ROUTING_ACTIVE_TEXT="$ROUTING_ACTIVE_TEXT

# ip -6 rule show
$v6_rules

# ip -6 route show table $ROUTING_V6_TABLE
$v6_routes"
        if ! routing_route_present 6 "$ROUTING_V6_PREFIX" "$ROUTING_V6_TABLE" || ! routing_rule_present 6 "$ROUTING_V6_PRIORITY" "$ROUTING_V6_MARK" "$ROUTING_V6_MASK" "$ROUTING_V6_TABLE"; then
            ROUTING_ACTIVE=0
        fi
    fi
    routing_error=''; rc=0
    [ "$locked_here" -eq 0 ] || routing_lock_release
    return "$rc"
}

if [ "${WLOC_ROUTING_HELPER_SOURCE:-0}" -ne 1 ]; then
    case "${1:-}" in
        validate)
            routing_parse_file "${2:-}" || { printf '%s\n' "${routing_error:-invalid routing configuration}" >&2; exit 1; }
            printf '%s\n' "$ROUTING_NORMALIZED"
            ;;
        apply)
            routing_apply_file "${2:-}" || { printf '%s\n' "${routing_error:-unable to apply routing configuration}" >&2; exit 1; }
            routing_collect_active || exit 1
            printf '%s\n' "$ROUTING_ACTIVE_TEXT"
            ;;
        save)
            routing_save_file "${2:-}" || { printf '%s\n' "${routing_error:-unable to save routing configuration}" >&2; exit 1; }
            printf '%s\n' "$ROUTING_NORMALIZED"
            ;;
        active)
            routing_collect_active || { printf '%s\n' "${routing_error:-unable to inspect routing configuration}" >&2; exit 1; }
            printf '%s\n' "$ROUTING_ACTIVE_TEXT"
            ;;
        ready)
            routing_collect_active >/dev/null 2>&1 && [ "$ROUTING_ACTIVE" -eq 1 ]
            ;;
        reset)
            routing_reset || { printf '%s\n' "${routing_error:-unable to reset routing configuration}" >&2; exit 1; }
            ;;
        *)
            printf '%s\n' 'usage: routing.sh {validate|apply|save} FILE | {active|ready|reset}' >&2
            exit 2
            ;;
    esac
fi
