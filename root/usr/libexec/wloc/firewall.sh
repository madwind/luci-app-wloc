#!/bin/sh

# Shared nftables transaction helper used by init and rpcd.

FIREWALL_RUNTIME_DIR=${WLOC_RUNTIME_DIR:-/var/run/wloc}
FIREWALL_RUNTIME=${WLOC_FIREWALL_RUNTIME:-${FIREWALL_RUNTIME_DIR}/firewall.applied.nft}
FIREWALL_RUNTIME_NEXT=${WLOC_FIREWALL_RUNTIME_NEXT:-${FIREWALL_RUNTIME}.next}
FIREWALL_PERSISTENT=${WLOC_FIREWALL_PATH:-/etc/wloc/firewall.nft}
FIREWALL_RULES=${WLOC_RULES_HELPER:-/usr/libexec/wloc/rules.sh}
FIREWALL_STATUS_PATH=${WLOC_STATUS_PATH:-/var/run/wloc/status.json}
FIREWALL_LOCK=${WLOC_FIREWALL_LOCK:-${FIREWALL_RUNTIME_DIR}/firewall.lock}
FIREWALL_LOCK_TIMEOUT=${WLOC_FIREWALL_LOCK_TIMEOUT:-5}
FIREWALL_LOCK_HELD=0
FIREWALL_LOCK_OWNER=''

firewall_set_error() {
    firewall_error_code="$1"
    firewall_error="$2"
}

firewall_process_start() {
    if [ -r "/proc/$$/stat" ]; then
        awk '{ print $22; exit }' "/proc/$$/stat"
    else
        printf '%s' unknown
    fi
}

firewall_lock_save_traps() {
    FIREWALL_LOCK_SAVED_EXIT_TRAP="$(trap -p EXIT 2>/dev/null || true)"
    [ -n "$FIREWALL_LOCK_SAVED_EXIT_TRAP" ] || \
        FIREWALL_LOCK_SAVED_EXIT_TRAP="$(trap -p 0 2>/dev/null || true)"
    FIREWALL_LOCK_SAVED_INT_TRAP="$(trap -p INT 2>/dev/null || true)"
    FIREWALL_LOCK_SAVED_TERM_TRAP="$(trap -p TERM 2>/dev/null || true)"
    FIREWALL_LOCK_SAVED_HUP_TRAP="$(trap -p HUP 2>/dev/null || true)"
}

firewall_lock_restore_trap() {
    local signal="$1" saved="$2"
    if [ -n "$saved" ]; then
        eval "$saved"
    else
        trap - "$signal"
    fi
}

firewall_lock_release() {
    local owner=''
    [ "${FIREWALL_LOCK_HELD:-0}" -eq 1 ] || return 0
    if [ -r "$FIREWALL_LOCK/owner" ]; then
        owner="$(cat "$FIREWALL_LOCK/owner" 2>/dev/null || true)"
    fi
    if [ "$owner" = "$FIREWALL_LOCK_OWNER" ]; then
        rm -f "$FIREWALL_LOCK/owner"
        rmdir "$FIREWALL_LOCK" 2>/dev/null || true
    fi
    FIREWALL_LOCK_HELD=0
    FIREWALL_LOCK_OWNER=''
    firewall_lock_restore_trap EXIT "${FIREWALL_LOCK_SAVED_EXIT_TRAP:-}"
    firewall_lock_restore_trap INT "${FIREWALL_LOCK_SAVED_INT_TRAP:-}"
    firewall_lock_restore_trap TERM "${FIREWALL_LOCK_SAVED_TERM_TRAP:-}"
    firewall_lock_restore_trap HUP "${FIREWALL_LOCK_SAVED_HUP_TRAP:-}"
    FIREWALL_LOCK_SAVED_EXIT_TRAP=''
    FIREWALL_LOCK_SAVED_INT_TRAP=''
    FIREWALL_LOCK_SAVED_TERM_TRAP=''
    FIREWALL_LOCK_SAVED_HUP_TRAP=''
}

firewall_lock_abort() {
    local status="$1"
    firewall_lock_release
    exit "$status"
}

firewall_lock_install_traps() {
    firewall_lock_save_traps
    trap 'firewall_lock_release' EXIT
    trap 'firewall_lock_abort 130' INT
    trap 'firewall_lock_abort 143' TERM
    trap 'firewall_lock_abort 129' HUP
}

firewall_lock_owner_alive() {
    local owner pid start current
    [ -r "$FIREWALL_LOCK/owner" ] || return 2
    owner="$(cat "$FIREWALL_LOCK/owner" 2>/dev/null || true)"
    pid="${owner%% *}"
    start="${owner#* }"
    case "$pid" in
        ''|*[!0-9]*) return 2;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    case "$start" in
        ''|unknown) return 0;;
    esac
    [ -r "/proc/$pid/stat" ] || return 0
    current="$(awk '{ print $22; exit }' "/proc/$pid/stat")"
    [ "$current" = "$start" ]
}

firewall_lock_remove_stale() {
    local owner_rc
    [ -d "$FIREWALL_LOCK" ] || return 1
    if [ ! -e "$FIREWALL_LOCK/owner" ]; then
        rmdir "$FIREWALL_LOCK" 2>/dev/null
        return $?
    fi
    if firewall_lock_owner_alive; then
        return 1
    else
        owner_rc=$?
    fi
    [ "$owner_rc" -eq 1 ] || return 1
    rm -f "$FIREWALL_LOCK/owner" || return 1
    rmdir "$FIREWALL_LOCK" 2>/dev/null
}

firewall_lock_acquire() {
    local lock_parent timeout attempt owner_start
    [ "${FIREWALL_LOCK_HELD:-0}" -eq 1 ] && return 0
    firewall_error_code=''
    firewall_error=''
    lock_parent="${FIREWALL_LOCK%/*}"
    [ "$lock_parent" = "$FIREWALL_LOCK" ] && lock_parent='.'
    mkdir -p "$lock_parent" || {
        firewall_set_error firewall_lock_failed 'unable to create the firewall lock directory'
        return 1
    }
    timeout="$FIREWALL_LOCK_TIMEOUT"
    case "$timeout" in
        ''|*[!0-9]*) timeout=5;;
    esac
    attempt=0
    while ! mkdir "$FIREWALL_LOCK" 2>/dev/null; do
        if firewall_lock_remove_stale; then
            continue
        fi
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
    chmod 0700 "$FIREWALL_LOCK" 2>/dev/null || {
        rmdir "$FIREWALL_LOCK" 2>/dev/null || true
        firewall_set_error firewall_lock_failed 'unable to initialize the firewall lock'
        return 1
    }
    owner_start="$(firewall_process_start)"
    FIREWALL_LOCK_OWNER="$$ $owner_start"
    if ! printf '%s\n' "$FIREWALL_LOCK_OWNER" >"$FIREWALL_LOCK/owner" || \
        ! chmod 0600 "$FIREWALL_LOCK/owner"; then
        rm -f "$FIREWALL_LOCK/owner"
        rmdir "$FIREWALL_LOCK" 2>/dev/null || true
        FIREWALL_LOCK_OWNER=''
        firewall_set_error firewall_lock_failed 'unable to record the firewall lock owner'
        return 1
    fi
    FIREWALL_LOCK_HELD=1
    firewall_lock_install_traps
}

firewall_tables() {
	[ -r "$1" ] || return 0
	awk '
		$1 == "table" && $2 ~ /^(ip|ip6|inet|arp|bridge|netdev)$/ && $3 ~ /^[A-Za-z0-9_.-]+$/ {
			print $2, $3
		}
		$1 == "add" && $2 == "table" && $3 ~ /^(ip|ip6|inet|arp|bridge|netdev)$/ && $4 ~ /^[A-Za-z0-9_.-]+$/ {
			print $3, $4
		}
	' "$1"
}

firewall_is_command_script() {
	grep -Eq '^[[:space:]]*(flush|add|delete|destroy|insert|replace|reset|include)([[:space:]]|$)' "$1"
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
	firewall_collect_active "$1" || return 1
	[ "$FIREWALL_ACTIVE_FOUND" -eq 1 ]
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
        if firewall_copy_atomic "$FIREWALL_RUNTIME" "$FIREWALL"; then
            FIREWALL_APPLIED_HASH="$current_hash"
            FIREWALL_SAVED_HASH="$(firewall_file_hash "$FIREWALL" 2>/dev/null || true)"
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
	# A command script has no generic inverse. Remove only table declarations
	# that can be identified explicitly; all other commands are best-effort.
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
	mkdir -p "$FIREWALL_RUNTIME_DIR" || {
		firewall_error='unable to create WLOC runtime directory'
		return 1
	}
	check="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-check.XXXXXX")" || {
		firewall_error='unable to create nftables check file'
		return 1
	}
	: >"$check"
	if ! firewall_is_command_script "$source"; then
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
	fi
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
	if ! firewall_is_command_script "$source"; then
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
	fi
	if ! cat "$source" >>"$transaction"; then
		rm -f "$transaction"
		rm -f "$FIREWALL_RUNTIME_NEXT"
		firewall_error='unable to read nftables configuration'
		return 1
	fi
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
			firewall_runtime_cleanup || true
			FIREWALL_RUNTIME_RECOVERING=1
			FIREWALL_RUNTIME_WARNING='Runtime rule refresh failed; WLOC will retry automatically.'
		fi
	else
		firewall_runtime_cleanup || true
		FIREWALL_RUNTIME_RECOVERING=1
		FIREWALL_RUNTIME_WARNING='Runtime dynamic sets are waiting for the WLOC listener; WLOC will retry automatically.'
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
			firewall_collect_active "${2:-}" || {
				printf '%s\n' 'nftables configuration file is not readable' >&2
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
