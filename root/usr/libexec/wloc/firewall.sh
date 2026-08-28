#!/bin/sh

# Shared nftables transaction helper used by init and rpcd.

FIREWALL_RUNTIME_DIR=${WLOC_RUNTIME_DIR:-/var/run/wloc}
FIREWALL_RUNTIME=${WLOC_FIREWALL_RUNTIME:-${FIREWALL_RUNTIME_DIR}/firewall.applied.nft}
FIREWALL_CANDIDATE=${WLOC_FIREWALL_CANDIDATE:-${FIREWALL_RUNTIME_DIR}/firewall.candidate.nft}
FIREWALL_PERSISTENT=${WLOC_FIREWALL_PATH:-/etc/wloc/firewall.nft}
FIREWALL_RULES=${WLOC_RULES_HELPER:-/usr/libexec/wloc/rules.sh}
FIREWALL_STATUS_PATH=${WLOC_STATUS_PATH:-/var/run/wloc/status.json}

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

firewall_copy_atomic() {
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
	if ! cp "$source" "$temporary" || ! chmod 0600 "$temporary" || ! mv -f "$temporary" "$destination"; then
		rm -f "$temporary"
		firewall_error='unable to atomically replace firewall snapshot'
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

firewall_remove_file() {
	local source="$1" transaction detail rc family name tables
	firewall_error=''
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

firewall_remove_runtime() {
	local source=''
	if [ -r "$FIREWALL_RUNTIME" ]; then
		source="$FIREWALL_RUNTIME"
	elif [ -r "$FIREWALL_PERSISTENT" ]; then
		source="$FIREWALL_PERSISTENT"
	fi
	if [ -n "$source" ]; then
		firewall_remove_file "$source" || return 1
	fi
	rm -f "$FIREWALL_RUNTIME" "$FIREWALL_CANDIDATE"
}

firewall_validate_file() {
	local source="$1" check detail rc family name tables
	firewall_error=''
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

firewall_apply_file() {
	local source="$1" transaction detail rc family name tables
	firewall_error=''
	FIREWALL_RUNTIME_STATE_SET=0
	FIREWALL_RUNTIME_READY=0
	FIREWALL_RUNTIME_RECOVERING=0
	FIREWALL_RUNTIME_WARNING=''
	firewall_validate_file "$source" || return 1
	mkdir -p "$FIREWALL_RUNTIME_DIR" || {
		firewall_error='unable to create WLOC runtime directory'
		return 1
	}
	transaction="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-apply.XXXXXX")" || {
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
		firewall_error='unable to read nftables configuration'
		return 1
	fi
	detail="$(nft --file "$transaction" 2>&1)" && rc=0 || rc=$?
	rm -f "$transaction"
	if [ "$rc" -ne 0 ]; then
		firewall_error="${detail:-failed to apply nftables rules}"
		return 1
	fi
	mkdir -p "${FIREWALL_RUNTIME%/*}" || {
		firewall_error='unable to create WLOC firewall snapshot directory'
		return 1
	}
	firewall_copy_atomic "$source" "$FIREWALL_RUNTIME" || {
		firewall_error="unable to save applied nftables snapshot: ${firewall_error:-unknown error}"
		return 1
	}
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
