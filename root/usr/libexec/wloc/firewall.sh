#!/bin/sh

# Shared nftables transaction helper used by init and rpcd.

FIREWALL_RUNTIME_DIR=${WLOC_RUNTIME_DIR:-/var/run/wloc}
FIREWALL_RUNTIME=${WLOC_FIREWALL_RUNTIME:-${FIREWALL_RUNTIME_DIR}/firewall.applied.nft}
FIREWALL_RUNTIME_NEXT=${WLOC_FIREWALL_RUNTIME_NEXT:-${FIREWALL_RUNTIME}.next}
FIREWALL_PERSISTENT=${WLOC_FIREWALL_PATH:-/etc/wloc/firewall.nft}
FIREWALL_RULES=${WLOC_RULES_HELPER:-/usr/libexec/wloc/rules.sh}
FIREWALL_STATUS_PATH=${WLOC_STATUS_PATH:-/var/run/wloc/status.json}
FIREWALL_LOCK=${WLOC_FIREWALL_LOCK:-/var/lock/wloc-firewall.lock}
FIREWALL_LOCK_COMMAND=${WLOC_FIREWALL_LOCK_COMMAND:-lock}
FIREWALL_LOCK_TIMEOUT=${WLOC_FIREWALL_LOCK_TIMEOUT:-5}
FIREWALL_LOCK_HELD=0

firewall_set_error() {
    firewall_error_code="$1"
    firewall_error="$2"
}

firewall_lock_release() {
    [ "${FIREWALL_LOCK_HELD:-0}" -eq 1 ] || return 0
    "$FIREWALL_LOCK_COMMAND" -u "$FIREWALL_LOCK" >/dev/null 2>&1 || true
    FIREWALL_LOCK_HELD=0
}

firewall_lock_acquire() {
    local lock_parent timeout attempt
    [ "${FIREWALL_LOCK_HELD:-0}" -eq 1 ] && return 0
    firewall_error_code=''
    firewall_error=''
    command -v "$FIREWALL_LOCK_COMMAND" >/dev/null 2>&1 || {
        firewall_set_error firewall_lock_failed 'OpenWrt lock utility is not available'
        return 1
    }
    lock_parent="${FIREWALL_LOCK%/*}"
    [ "$lock_parent" = "$FIREWALL_LOCK" ] && lock_parent='.'
    mkdir -p "$lock_parent" || {
        firewall_set_error firewall_lock_failed 'unable to create the firewall lock parent directory'
        return 1
    }
    timeout="$FIREWALL_LOCK_TIMEOUT"
    case "$timeout" in
        ''|*[!0-9]*) timeout=5;;
    esac
    attempt=0
    while ! "$FIREWALL_LOCK_COMMAND" -n "$FIREWALL_LOCK" >/dev/null 2>&1; do
        if [ "$attempt" -ge "$timeout" ]; then
            firewall_set_error firewall_busy 'Another firewall operation is already in progress. Please retry.'
            return 1
        fi
        sleep 1 || {
            firewall_set_error firewall_busy 'Another firewall operation is already in progress. Please retry.'
            return 1
        }
        attempt=$((attempt + 1))
    done
    FIREWALL_LOCK_HELD=1
}

firewall_tables() {
    [ -r "$1" ] || return 0
    awk '
        $1 == "table" && $2 ~ /^(ip|ip6|inet|arp|bridge|netdev)$/ && $3 ~ /^[A-Za-z0-9_.-]+$/ {
            print $2, $3
        }
    ' "$1"
}

firewall_validate_declarative() {
    local source="$1"
    if grep -Eq '^[[:space:]]*(add|flush|include|delete|destroy|reset|insert|replace)([[:space:]]|$)' "$source"; then
        firewall_error_code='unsupported_firewall_command'
        firewall_error='Only declarative nftables table definitions are supported.'
        return 1
    fi
    if ! awk '
        BEGIN {
            depth = 0
            top_started = 0
            quote = ""
            escaped = 0
            valid = 1
        }
        {
            in_comment = 0
            for (i = 1; i <= length($0); i++) {
                character = substr($0, i, 1)
                if (in_comment)
                    break
                if (quote != "") {
                    if (escaped)
                        escaped = 0
                    else if (character == "\\")
                        escaped = 1
                    else if (character == quote)
                        quote = ""
                    continue
                }
                if (character == "\"" || character == "\047") {
                    quote = character
                    continue
                }
                if (character == "#") {
                    in_comment = 1
                    continue
                }
                if (depth == 0 && !top_started) {
                    if (character ~ /[[:space:]]/)
                        continue
                    if (character !~ /[A-Za-z_]/) {
                        valid = 0
                        exit 1
                    }
                    word = character
                    i++
                    while (i <= length($0) && substr($0, i, 1) ~ /[A-Za-z0-9_-]/) {
                        word = word substr($0, i, 1)
                        i++
                    }
                    i--
                    if (word != "table") {
                        valid = 0
                        exit 1
                    }
                    header = substr($0, i + 1)
                    if (header !~ /^[[:space:]]+(ip|ip6|inet|arp|bridge|netdev)[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+\{/) {
                        valid = 0
                        exit 1
                    }
                    top_started = 1
                    continue
                }
                if (character == "{") {
                    depth++
                } else if (character == "}") {
                    if (depth == 0) {
                        valid = 0
                        exit 1
                    }
                    depth--
                    if (depth == 0)
                        top_started = 0
                }
            }
        }
        END {
            if (valid && depth == 0 && !top_started && quote == "")
                exit 0
            exit 1
        }
    ' "$source"; then
        firewall_error_code='unsupported_firewall_command'
        firewall_error='Only declarative nftables table definitions are supported.'
        return 1
    fi
}

firewall_collect_active() {
    local source="$1" active family name table_count active_count table_dump
    FIREWALL_ACTIVE=''
    FIREWALL_TABLE_COUNT=0
    FIREWALL_ACTIVE_TABLE_COUNT=0
    FIREWALL_ACTIVE_FOUND=0
    [ -r "$source" ] || return 1
    active=''
    table_count=0
    active_count=0
    while read -r family name; do
        [ -n "$family" ] || continue
        table_count=$((table_count + 1))
        if table_dump="$(nft list table "$family" "$name" 2>/dev/null)"; then
            active_count=$((active_count + 1))
            if [ -n "$active" ]; then
                active="$active

$table_dump"
            else
                active="$table_dump"
            fi
        fi
    done <<EOF
$(firewall_tables "$source")
EOF
    FIREWALL_ACTIVE="$active"
    FIREWALL_TABLE_COUNT="$table_count"
    FIREWALL_ACTIVE_TABLE_COUNT="$active_count"
    if [ "$table_count" -eq "$active_count" ]; then
        FIREWALL_ACTIVE_FOUND=1
    fi
    return 0
}

firewall_active() {
    local locked_here=0 rc
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if firewall_collect_active "$1" && [ "$FIREWALL_ACTIVE_FOUND" -eq 1 ]; then
        rc=0
    else
        rc=1
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

firewall_file_hash() {
    local source="$1"
    [ -r "$source" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$source" | awk '{ print $1; exit }'
    else
        cksum "$source" | awk '{ print $1 ":" $2; exit }'
    fi
}

firewall_sync_file() {
    local path="$1"
    command -v sync >/dev/null 2>&1 || return 0
    sync -f "$path" >/dev/null 2>&1 && return 0
    sync >/dev/null 2>&1
}

_firewall_copy_atomic() {
    local source="$1" destination="$2" directory temporary
    [ -r "$source" ] || {
        firewall_error='source file is not readable'
        return 1
    }
    directory="${destination%/*}"
    [ "$directory" = "$destination" ] && directory='.'
    mkdir -p "$directory" || {
        firewall_error='unable to create firewall snapshot directory'
        return 1
    }
    temporary="$(mktemp "${destination}.XXXXXX")" || {
        firewall_error='unable to create firewall snapshot'
        return 1
    }
    if ! cp "$source" "$temporary" || ! chmod 0600 "$temporary" || ! firewall_sync_file "$temporary"; then
        rm -f "$temporary"
        firewall_error='unable to write firewall snapshot'
        return 1
    fi
    if ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        firewall_error='unable to atomically replace firewall snapshot'
        return 1
    fi
}

firewall_copy_atomic() {
    local locked_here=0 rc
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if _firewall_copy_atomic "$@"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

firewall_save_snapshot() {
    local expected="${1:-}" current_hash locked_here=0 rc=1
    firewall_error_code=''
    firewall_error=''
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if [ ! -r "$FIREWALL_RUNTIME" ]; then
        firewall_set_error no_applied_snapshot 'No successfully applied firewall rules are available to save.'
    elif ! current_hash="$(firewall_file_hash "$FIREWALL_RUNTIME")"; then
        firewall_set_error no_applied_snapshot 'The applied firewall snapshot could not be hashed.'
    elif [ -z "$expected" ] || [ "$expected" != "$current_hash" ]; then
        firewall_set_error stale_applied_revision 'The applied firewall configuration changed. Refresh the page before saving.'
    else
        firewall_error_code='persistent_save_failed'
        if firewall_copy_atomic \
            "$FIREWALL_RUNTIME" \
            "$FIREWALL_PERSISTENT"; then
            FIREWALL_APPLIED_HASH="$current_hash"
            FIREWALL_SAVED_HASH="$(firewall_file_hash "$FIREWALL_PERSISTENT" 2>/dev/null || true)"
            rc=0
        else
            firewall_error="${firewall_error:-unable to persist the applied firewall snapshot}"
        fi
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

firewall_stage_snapshot() {
    local source="$1"
    firewall_error_code='snapshot_stage_failed'
    [ "$FIREWALL_RUNTIME_NEXT" != "$FIREWALL_RUNTIME" ] || {
        firewall_error='runtime snapshot staging path must differ from the applied snapshot'
        return 1
    }
    if ! rm -f "$FIREWALL_RUNTIME_NEXT"; then
        firewall_error='unable to clear the previous staged firewall snapshot'
        return 1
    fi
    firewall_copy_atomic "$source" "$FIREWALL_RUNTIME_NEXT" || {
        firewall_error="unable to stage applied nftables snapshot: ${firewall_error:-unknown error}"
        return 1
    }
}

firewall_promote_snapshot() {
    local staged="$1"
    firewall_error_code='snapshot_promote_failed'
    [ -f "$staged" ] || {
        firewall_error='fatal consistency error: staged nftables snapshot is missing'
        return 1
    }
    if ! mv -f "$staged" "$FIREWALL_RUNTIME" || [ ! -f "$FIREWALL_RUNTIME" ]; then
        firewall_error='fatal consistency error: nftables transaction succeeded but the applied snapshot could not be promoted'
        return 1
    fi
}

firewall_wloc_ready() {
    pidof wlocd >/dev/null 2>&1 && [ -s "$FIREWALL_STATUS_PATH" ]
}

firewall_runtime_reconcile() {
    local port detail
    port="$(uci -q get wloc.main.listen_port 2>/dev/null)" || {
        firewall_error='unable to read the WLOC listen port'
        return 1
    }
    [ -n "$port" ] || {
        firewall_error='the WLOC listen port is empty'
        return 1
    }
    if ! detail="$("$FIREWALL_RULES" reconcile "$port" 2>&1)"; then
        firewall_error="WLOC runtime rule refresh failed: ${detail:-unknown error}"
        return 1
    fi
}

firewall_runtime_cleanup() {
    local detail
    if ! detail="$("$FIREWALL_RULES" cleanup 2>&1)"; then
        firewall_error="WLOC dynamic-set cleanup failed: ${detail:-unknown error}"
        return 1
    fi
}

_firewall_remove_file() {
    local source="$1" transaction detail rc family name tables
    firewall_error=''
    firewall_error_code='nft_apply_failed'
    [ -r "$source" ] || {
        firewall_error='nftables configuration file is not readable'
        return 1
    }
    mkdir -p "$FIREWALL_RUNTIME_DIR" || {
        firewall_error='unable to create WLOC runtime directory'
        return 1
    }
    transaction="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-remove.XXXXXX")" || {
        firewall_error='unable to create nftables removal transaction'
        return 1
    }
    : >"$transaction"
    # Only declarative table declarations are owned. Legacy command snapshots
    # may still exist after an upgrade, but they have no generic inverse and
    # are therefore ignored during cleanup.
    tables="$(firewall_tables "$source" | awk '!seen[$0]++')"
    while read -r family name; do
        [ -n "$family" ] || continue
        if nft list table "$family" "$name" >/dev/null 2>&1; then
            printf 'delete table %s %s\n' "$family" "$name" >>"$transaction" || {
                rm -f "$transaction"
                firewall_error='unable to build nftables removal transaction'
                return 1
            }
        fi
    done <<EOF
$tables
EOF
    if [ ! -s "$transaction" ]; then
        rm -f "$transaction"
        return 0
    fi
    detail="$(nft --check --file "$transaction" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$transaction"
        firewall_error_code='nft_check_failed'
        firewall_error="${detail:-nftables removal syntax check failed}"
        return 1
    fi
    detail="$(nft --file "$transaction" 2>&1)" && rc=0 || rc=$?
    rm -f "$transaction"
    [ "$rc" -eq 0 ] || {
        firewall_error="${detail:-failed to remove nftables tables}"
        return 1
    }
}

firewall_remove_file() {
    local locked_here=0 rc
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if _firewall_remove_file "$@"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

_firewall_remove_runtime() {
    local source=''
    if [ -r "$FIREWALL_RUNTIME" ]; then
        source="$FIREWALL_RUNTIME"
    elif [ -r "$FIREWALL_PERSISTENT" ]; then
        source="$FIREWALL_PERSISTENT"
    fi
    if [ -n "$source" ]; then
        _firewall_remove_file "$source" || return 1
    fi
    rm -f "$FIREWALL_RUNTIME" "$FIREWALL_RUNTIME_NEXT"
}

firewall_remove_runtime() {
    local locked_here=0 rc
    firewall_error_code=''
    firewall_error=''
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if _firewall_remove_runtime "$@"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

_firewall_validate_file() {
    local source="$1" check detail rc family name tables
    firewall_error=''
    firewall_error_code='nft_check_failed'
    [ -r "$source" ] || {
        firewall_error='nftables configuration file is not readable'
        return 1
    }
    firewall_validate_declarative "$source" || return 1
    mkdir -p "$FIREWALL_RUNTIME_DIR" || {
        firewall_error='unable to create WLOC runtime directory'
        return 1
    }
    check="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-check.XXXXXX")" || {
        firewall_error='unable to create nftables check file'
        return 1
    }
    : >"$check"
    tables="$(firewall_tables "$source")"
    while read -r family name; do
        [ -n "$family" ] || continue
        if nft list table "$family" "$name" >/dev/null 2>&1; then
            printf 'delete table %s %s\n' "$family" "$name" >>"$check" || {
                rm -f "$check"
                firewall_error='unable to build nftables check transaction'
                return 1
            }
        fi
    done <<EOF
$tables
EOF
    if ! cat "$source" >>"$check"; then
        rm -f "$check"
        firewall_error='unable to read nftables configuration'
        return 1
    fi
    detail="$(nft --check --file "$check" 2>&1)" && rc=0 || rc=$?
    rm -f "$check"
    [ "$rc" -eq 0 ] || {
        firewall_error="${detail:-nftables syntax check failed}"
        return 1
    }
}

firewall_validate_file() {
    local locked_here=0 rc
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if _firewall_validate_file "$@"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

_firewall_apply_file() {
    local source="$1" transaction detail rc family name tables
    firewall_error=''
    firewall_error_code='nft_apply_failed'
    FIREWALL_RUNTIME_STATE_SET=0
    FIREWALL_RUNTIME_READY=0
    FIREWALL_RUNTIME_RECOVERING=0
    FIREWALL_RUNTIME_WARNING=''
    FIREWALL_RUNTIME_PROMOTION_FAILED=0
    mkdir -p "$FIREWALL_RUNTIME_DIR" || {
        firewall_error='unable to create WLOC runtime directory'
        return 1
    }
    firewall_stage_snapshot "$source" || return 1
    if ! firewall_validate_file "$source"; then
        rm -f "$FIREWALL_RUNTIME_NEXT"
        return 1
    fi
    transaction="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-apply.XXXXXX")" || {
        rm -f "$FIREWALL_RUNTIME_NEXT"
        firewall_error='unable to create nftables apply transaction'
        return 1
    }
    : >"$transaction"
    tables="$( { firewall_tables "$FIREWALL_RUNTIME"; firewall_tables "$source"; } | awk '!seen[$0]++')"
    while read -r family name; do
        [ -n "$family" ] || continue
        if nft list table "$family" "$name" >/dev/null 2>&1; then
            printf 'delete table %s %s\n' "$family" "$name" >>"$transaction" || {
                rm -f "$transaction"
                rm -f "$FIREWALL_RUNTIME_NEXT"
                firewall_error='unable to build nftables apply transaction'
                return 1
            }
        fi
    done <<EOF
$tables
EOF
    if ! cat "$source" >>"$transaction"; then
        rm -f "$transaction"
        rm -f "$FIREWALL_RUNTIME_NEXT"
        firewall_error='unable to read nftables configuration'
        return 1
    fi
    firewall_error_code='nft_apply_failed'
    detail="$(nft --file "$transaction" 2>&1)" && rc=0 || rc=$?
    rm -f "$transaction"
    if [ "$rc" -ne 0 ]; then
        rm -f "$FIREWALL_RUNTIME_NEXT"
        firewall_error="${detail:-failed to apply nftables rules}"
        return 1
    fi
    if ! firewall_promote_snapshot "$FIREWALL_RUNTIME_NEXT"; then
        FIREWALL_RUNTIME_PROMOTION_FAILED=1
        firewall_error="${firewall_error:-fatal consistency error: unable to promote applied nftables snapshot}"
        detail="$firewall_error"
        firewall_runtime_cleanup || true
        firewall_error="$detail"
        return 1
    fi
    FIREWALL_RUNTIME_STATE_SET=1
    if firewall_wloc_ready; then
        if firewall_runtime_reconcile; then
            FIREWALL_RUNTIME_READY=1
        else
            # The nft transaction and applied snapshot already succeeded. Keep the
            # completed Apply successful, but remove dynamic state fail-open while
            # the daemon retries reconciliation.
            if firewall_runtime_cleanup; then
                FIREWALL_RUNTIME_WARNING='Runtime rule refresh failed; WLOC will retry automatically.'
            else
                FIREWALL_RUNTIME_WARNING='Runtime rule refresh failed and fail-open cleanup also failed; WLOC will retry automatically.'
            fi
            FIREWALL_RUNTIME_RECOVERING=1
        fi
    else
        if firewall_runtime_cleanup; then
            FIREWALL_RUNTIME_WARNING='Runtime dynamic sets are waiting for the WLOC listener; WLOC will retry automatically.'
        else
            FIREWALL_RUNTIME_WARNING='WLOC listener is not ready and fail-open cleanup failed; WLOC will retry automatically.'
        fi
        FIREWALL_RUNTIME_RECOVERING=1
    fi
}

firewall_apply_file() {
    local locked_here=0 rc
    FIREWALL_RUNTIME_PROMOTION_FAILED=0
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if _firewall_apply_file "$@"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$locked_here" -eq 1 ]; then
        firewall_lock_release
    fi
    return "$rc"
}

if [ "${WLOC_FIREWALL_HELPER_SOURCE:-0}" -ne 1 ]; then
    case "${1:-}" in
        validate)
            firewall_validate_file "${2:-}" || {
                printf '%s\n' "${firewall_error:-nftables syntax check failed}" >&2
                exit 1
            }
            ;;
        apply)
            firewall_apply_file "${2:-}" || {
                printf '%s\n' "${firewall_error:-failed to apply nftables rules}" >&2
                exit 1
            }
            ;;
        active)
            firewall_active "${2:-}" || {
                printf '%s\n' "${firewall_error:-nftables configuration file is not readable}" >&2
                exit 1
            }
            printf '%s\n' "${FIREWALL_ACTIVE:-# No custom nftables tables are active.}"
            [ "$FIREWALL_ACTIVE_FOUND" -eq 1 ] || exit 1
            ;;
        remove)
            firewall_remove_file "${2:-}" || {
                printf '%s\n' "${firewall_error:-failed to remove nftables tables}" >&2
                exit 1
            }
            ;;
        remove-runtime)
            firewall_remove_runtime || {
                printf '%s\n' "${firewall_error:-failed to remove runtime nftables tables}" >&2
                exit 1
            }
            ;;
        *)
            printf '%s\n' 'usage: firewall.sh {validate|apply|active|remove} FILE | remove-runtime' >&2
            exit 2
            ;;
    esac
fi
