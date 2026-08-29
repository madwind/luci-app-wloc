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
FIREWALL_BRIDGE_FAMILY=bridge
FIREWALL_INET_FAMILY=inet
FIREWALL_TABLE=wloc
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

# The editor owns exactly two tables. This check deliberately only looks at
# table headers and command forms; nft --check remains the syntax validator.
firewall_validate_ownership() {
    local source="$1"
    if grep -Eq '^[[:space:]]*(add|flush|include|delete|destroy|reset|insert|replace)([[:space:]]|$)' "$source"; then
        firewall_error_code='unsupported_firewall_command'
        firewall_error='Only declarative definitions of table bridge wloc and table inet wloc are supported.'
        return 1
    fi
    if ! awk '
        /^[[:space:]]*table([[:space:]]|$)/ &&
            $0 !~ /^[[:space:]]*table[[:space:]]+(bridge|inet)[[:space:]]+wloc([[:space:]]|$)/ {
            exit 1
        }
    ' "$source"; then
        firewall_error_code='unsupported_firewall_command'
        firewall_error='WLOC owns only table bridge wloc and table inet wloc.'
        return 1
    fi
}

firewall_append_table_deletes() {
    local destination="$1" family
    for family in "$FIREWALL_BRIDGE_FAMILY" "$FIREWALL_INET_FAMILY"; do
        if nft list table "$family" "$FIREWALL_TABLE" >/dev/null 2>&1; then
            printf 'delete table %s %s\n' "$family" "$FIREWALL_TABLE" >>"$destination" || {
                firewall_error='unable to build the nftables transaction'
                return 1
            }
        fi
    done
}

firewall_collect_active() {
    local active bridge_dump inet_dump
    FIREWALL_ACTIVE=''
    FIREWALL_BRIDGE_ACTIVE=''
    FIREWALL_INET_ACTIVE=''
    FIREWALL_BRIDGE_ACTIVE_FOUND=0
    FIREWALL_INET_ACTIVE_FOUND=0
    FIREWALL_TABLE_COUNT=2
    FIREWALL_ACTIVE_TABLE_COUNT=0
    FIREWALL_ACTIVE_FOUND=0
    active=''

    if bridge_dump="$(nft list table "$FIREWALL_BRIDGE_FAMILY" "$FIREWALL_TABLE" 2>/dev/null)"; then
        FIREWALL_BRIDGE_ACTIVE_FOUND=1
        FIREWALL_ACTIVE_TABLE_COUNT=$((FIREWALL_ACTIVE_TABLE_COUNT + 1))
        FIREWALL_BRIDGE_ACTIVE="$bridge_dump"
        active="$bridge_dump"
    fi
    if inet_dump="$(nft list table "$FIREWALL_INET_FAMILY" "$FIREWALL_TABLE" 2>/dev/null)"; then
        FIREWALL_INET_ACTIVE_FOUND=1
        FIREWALL_ACTIVE_TABLE_COUNT=$((FIREWALL_ACTIVE_TABLE_COUNT + 1))
        FIREWALL_INET_ACTIVE="$inet_dump"
        if [ -n "$active" ]; then
            active="$active

$inet_dump"
        else
            active="$inet_dump"
        fi
    fi
    FIREWALL_ACTIVE="$active"
    [ "$FIREWALL_ACTIVE_TABLE_COUNT" -eq 2 ] && FIREWALL_ACTIVE_FOUND=1
    return 0
}

firewall_active() {
    local locked_here=0 rc
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if firewall_collect_active && [ "$FIREWALL_ACTIVE_FOUND" -eq 1 ]; then
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

_firewall_remove_tables() {
    local family
    firewall_error=''
    firewall_error_code='nft_apply_failed'
    for family in "$FIREWALL_BRIDGE_FAMILY" "$FIREWALL_INET_FAMILY"; do
        if nft list table "$family" "$FIREWALL_TABLE" >/dev/null 2>&1; then
            if ! nft delete table "$family" "$FIREWALL_TABLE" >/dev/null 2>&1; then
                firewall_error="failed to remove nftables table $family $FIREWALL_TABLE"
                return 1
            fi
        fi
    done
}

_firewall_remove_runtime() {
    _firewall_remove_tables || return 1
    if ! rm -f "$FIREWALL_RUNTIME" "$FIREWALL_RUNTIME_NEXT"; then
        firewall_error='unable to remove WLOC runtime firewall snapshots'
        return 1
    fi
}

firewall_remove_runtime() {
    local locked_here=0 rc
    firewall_error_code=''
    firewall_error=''
    if [ "${FIREWALL_LOCK_HELD:-0}" -ne 1 ]; then
        firewall_lock_acquire || return 1
        locked_here=1
    fi
    if _firewall_remove_runtime; then
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
    local source="$1" check detail rc
    firewall_error=''
    firewall_error_code='nft_check_failed'
    [ -r "$source" ] || {
        firewall_error='nftables configuration file is not readable'
        return 1
    }
    firewall_validate_ownership "$source" || return 1
    mkdir -p "$FIREWALL_RUNTIME_DIR" || {
        firewall_error='unable to create WLOC runtime directory'
        return 1
    }
    check="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-check.XXXXXX")" || {
        firewall_error='unable to create nftables check file'
        return 1
    }
    : >"$check"
    if ! firewall_append_table_deletes "$check" || ! cat "$source" >>"$check"; then
        rm -f "$check"
        firewall_error="${firewall_error:-unable to build nftables check transaction}"
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
    local source="$1" transaction detail rc promotion_error rollback_error cleanup_error
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
    if ! firewall_append_table_deletes "$transaction" || ! cat "$source" >>"$transaction"; then
        rm -f "$transaction" "$FIREWALL_RUNTIME_NEXT"
        firewall_error="${firewall_error:-unable to build nftables apply transaction}"
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
        promotion_error="${firewall_error:-fatal consistency error: unable to promote applied nftables snapshot}"
        rollback_error=''
        cleanup_error=''
        if ! _firewall_remove_tables; then
            rollback_error="${firewall_error:-unable to remove the newly applied WLOC tables}"
        fi
        if ! rm -f "$FIREWALL_RUNTIME" "$FIREWALL_RUNTIME_NEXT"; then
            if [ -n "$rollback_error" ]; then
                rollback_error="$rollback_error; unable to invalidate firewall snapshots"
            else
                rollback_error='unable to invalidate firewall snapshots'
            fi
        fi
        if ! firewall_runtime_cleanup; then
            cleanup_error="${firewall_error:-unable to clear runtime dynamic sets}"
        fi
        firewall_error="$promotion_error"
        [ -z "$rollback_error" ] || \
            firewall_error="$firewall_error; rollback failed: $rollback_error"
        [ -z "$cleanup_error" ] || \
            firewall_error="$firewall_error; fail-open cleanup failed: $cleanup_error"
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
            firewall_active || {
                printf '%s\n' "${firewall_error:-both WLOC nftables tables are not active}" >&2
                exit 1
            }
            printf '%s\n' "${FIREWALL_ACTIVE:-# No WLOC nftables tables are active.}"
            ;;
        remove-runtime)
            firewall_remove_runtime || {
                printf '%s\n' "${firewall_error:-failed to remove WLOC nftables tables}" >&2
                exit 1
            }
            ;;
        *)
            printf '%s\n' 'usage: firewall.sh {validate|apply|active} FILE | remove-runtime' >&2
            exit 2
            ;;
    esac
fi
