#!/bin/sh

# Shared nftables transaction helper used by init and rpcd.

FIREWALL_RUNTIME=${WLOC_FIREWALL_RUNTIME:-/var/run/wloc/firewall.applied.nft}
FIREWALL_RULES=${WLOC_RULES_HELPER:-/usr/libexec/wloc/rules.sh}

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

firewall_validate_file() {
	local source="$1" check detail rc family name tables
	firewall_error=''
	[ -r "$source" ] || {
		firewall_error='nftables configuration file is not readable'
		return 1
	}
	mkdir -p /var/run/wloc || {
		firewall_error='unable to create WLOC runtime directory'
		return 1
	}
	check="$(mktemp /var/run/wloc/firewall-check.XXXXXX)" || {
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
	local source="$1" transaction detail rc family name tables runtime_tmp
	firewall_error=''
	firewall_validate_file "$source" || return 1
	mkdir -p /var/run/wloc || {
		firewall_error='unable to create WLOC runtime directory'
		return 1
	}
	transaction="$(mktemp /var/run/wloc/firewall-apply.XXXXXX)" || {
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
	runtime_tmp="$(mktemp "${FIREWALL_RUNTIME}.XXXXXX")" || {
		firewall_error='unable to create WLOC firewall snapshot'
		return 1
	}
	if ! cp "$source" "$runtime_tmp" || ! chmod 0600 "$runtime_tmp" || ! mv -f "$runtime_tmp" "$FIREWALL_RUNTIME"; then
		rm -f "$runtime_tmp"
		firewall_error='unable to save applied nftables snapshot'
		return 1
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
		*)
			printf '%s\n' 'usage: firewall.sh {validate|apply|active} FILE' >&2
			exit 2
			;;
	esac
fi
