#!/bin/sh
# Dedicated fail-open interception lifecycle for OpenWrt WLOC.

set -eu

TABLE=wloc
INGRESS_SET=target_ingress_interfaces
HOST_SET=apple_wloc_v4
# The firewall helper updates this snapshot only after nft succeeds, so DNS
# maintenance follows the active configuration rather than unsaved state.
CUSTOM_FIREWALL=/var/run/wloc/firewall.applied.nft
STAMP=/var/run/wloc/hosts.refreshed
DNS_ATTEMPT_STAMP=/var/run/wloc/hosts.attempted
AP_LIB=${WLOC_AP_LIB_PATH:-/usr/libexec/wloc/ap-lib.sh}
DEFAULT_HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'
HOSTS="$DEFAULT_HOSTS"
HOST_TIMEOUT=15m
DNS_SAMPLES=1
DNS_REFRESH_SECONDS=300
DNS_RETRY_SECONDS=10
INGRESS_INTERFACE_TIMEOUT=120s

append_configured_host() {
	[ -n "$1" ] || return 0
	HOSTS="${HOSTS}${HOSTS:+ }$1"
}

load_configured_hosts() {
	HOSTS=''
	if [ -r /lib/functions.sh ]; then
		# OpenWrt's helper reads this installer-only variable directly. Keep
		# strict mode enabled while making runtime invocations safe.
		IPKG_INSTROOT=${IPKG_INSTROOT:-}
		CONFIG_LIST_STATE=${CONFIG_LIST_STATE:-}
		NO_CALLBACK=${NO_CALLBACK:-}
		. /lib/functions.sh
		config_load wloc 2>/dev/null || true
		config_list_foreach main domain append_configured_host
	fi
	[ -n "$HOSTS" ] || HOSTS="$DEFAULT_HOSTS"
}

set_hosts() {
	if [ "$#" -gt 0 ]; then
		HOSTS="$*"
	else
		load_configured_hosts
	fi
}

active_ingress_set() {
	local family
	for family in bridge inet; do
		if nft list set "$family" "$TABLE" "$INGRESS_SET" >/dev/null 2>&1; then
			printf '%s %s\n' "$family" "$INGRESS_SET"
			return 0
		fi
	done
	return 1
}

clear_ingress_interfaces() {
	local family set
	read -r family set <<EOF
$(active_ingress_set)
EOF
	[ -n "$family" ] && [ -n "$set" ] || return 0
	nft flush set "$family" "$TABLE" "$set" >/dev/null 2>&1 || return 1
}

clear_host_sets() {
	local family table_name
	while read -r family table_name; do
		[ -n "$family" ] || continue
		if nft list set "$family" "$table_name" "$HOST_SET" >/dev/null 2>&1; then
			nft flush set "$family" "$table_name" "$HOST_SET" >/dev/null 2>&1 || return 1
		fi
	done <<EOF
$(host_set_targets)
EOF
}

cleanup() {
	local rc=0
	clear_ingress_interfaces || rc=1
	clear_host_sets || rc=1
	rm -f "$STAMP" "$DNS_ATTEMPT_STAMP" || rc=1
	return "$rc"
}

valid_port() {
	case "$1" in ''|*[!0-9]*) return 1;; esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4() {
	case "$1" in ''|*[!0-9.]*) return 1;; esac
	oldifs=$IFS; IFS=.; set -- $1; IFS=$oldifs
	[ "$#" -eq 4 ] || return 1
	for octet in "$@"; do [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] 2>/dev/null || return 1; done
}

host_set_targets() {
	{
		printf 'inet %s\n' "$TABLE"
		[ ! -s "$CUSTOM_FIREWALL" ] || awk -v host_set="$HOST_SET" '
			{
				line = $0
				sub(/#.*/, "", line)
				gsub(/[{};]/, "\n", line)
				count = split(line, statements, "\n")
				for (i = 1; i <= count; i++) {
					fields = split(statements[i], words, /[[:space:]]+/)
					first = 1
					while (first <= fields && words[first] == "") first++
					if (words[first] == "table") {
						family = words[first + 1]
						table_name = words[first + 2]
					} else if (words[first] == "add" && words[first + 1] == "table") {
						family = words[first + 2]
						table_name = words[first + 3]
					} else if (words[first] == "set" && words[first + 1] == host_set \
						&& family != "" && table_name != "") {
						print family, table_name
					} else if (words[first] == "add" && words[first + 1] == "set" \
						&& words[first + 2] == host_set) {
						print words[first + 3], words[first + 4]
					}
				}
			}
		' "$CUSTOM_FIREWALL"
	} | awk '!seen[$0]++'
}

host_set_available() {
	local family table_name
	while read -r family table_name; do
		[ -n "$family" ] || continue
		if nft list set "$family" "$table_name" "$HOST_SET" >/dev/null 2>&1; then
			return 0
		fi
	done <<EOF
$(host_set_targets)
EOF
	return 1
}

host_set_compatible() {
	printf '%s\n' "$1" | grep -q 'type ipv4_addr' &&
		printf '%s\n' "$1" | grep -Eq 'flags timeout|^[[:space:]]*timeout[[:space:]]'
}

host_set_has_elements() {
	printf '%s\n' "$1" | awk '
		/elements[[:space:]]*=/ { in_elements = 1 }
		in_elements && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ { found = 1 }
		in_elements && /}/ {
			if (found) exit 0
			in_elements = 0
		}
		END { exit(found ? 0 : 1) }
	'
}

resolve_hosts() {
	local now last attempt addresses host resolved_ip sample family table_name set_dump
	local compatible_targets has_elements maintenance_failed
	# Do not perform DNS work when neither the automatic table nor a custom
	# table currently exposes the managed set.
	host_set_available || return 0
	[ -d "${STAMP%/*}" ] || mkdir -p "${STAMP%/*}"
	now="$(date +%s)"
	last="$(cat "$STAMP" 2>/dev/null || echo 0)"
	[ $((now - last)) -ge "$DNS_REFRESH_SECONDS" ] || return 0
	attempt="$(cat "$DNS_ATTEMPT_STAMP" 2>/dev/null || echo 0)"
	[ $((now - attempt)) -ge "$DNS_RETRY_SECONDS" ] || return 0
	printf '%s\n' "$now" >"$DNS_ATTEMPT_STAMP"
	addresses=''
	for host in $HOSTS; do
		sample=0
		while [ "$sample" -lt "$DNS_SAMPLES" ]; do
			# BusyBox nslookup prints the DNS server as an Address before the
			# answer Name. Parse only Address lines in the answer section.
			for resolved_ip in $(nslookup "$host" 127.0.0.1 2>/dev/null \
				| sed -n '/^Name:[[:space:]]/,$ s/^Address[^:]*:[[:space:]]*\([0-9][0-9.]*\).*$/\1/p'); do
				valid_ipv4 "$resolved_ip" || continue
				case " $addresses " in
					*" $resolved_ip "*) :;;
					*) addresses="${addresses} ${resolved_ip}";;
				esac
			done
			sample=$((sample + 1))
		done
	done
	if [ -z "$addresses" ]; then
		compatible_targets=0
		has_elements=0
		maintenance_failed=0
		while read -r family table_name; do
			[ -n "$family" ] || continue
			if ! set_dump="$(nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null)"; then
				maintenance_failed=1
				continue
			fi
			if ! host_set_compatible "$set_dump"; then
				maintenance_failed=1
				continue
			fi
			compatible_targets=1
			host_set_has_elements "$set_dump" && has_elements=1
		done <<EOF
$(host_set_targets)
EOF
		if [ "$maintenance_failed" -eq 1 ] || [ "$compatible_targets" -eq 0 ]; then
			echo 'wloc: DNS resolution failed and the host set could not be verified' >&2
			return 1
		fi
		if [ "$has_elements" -eq 1 ]; then
			# Keep known CDN addresses until their nftables timeout expires.
			return 0
		fi
		echo 'wloc: DNS resolution failed and the WLOC host set is empty' >&2
		return 1
	fi
	compatible_targets=0
	maintenance_failed=0
	while read -r family table_name; do
		[ -n "$family" ] || continue
		if ! set_dump="$(nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null)"; then
			maintenance_failed=1
			continue
		fi
		if ! host_set_compatible "$set_dump"; then
			maintenance_failed=1
			continue
		fi
		compatible_targets=1
		for resolved_ip in $addresses; do
			if nft get element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip }" >/dev/null 2>&1; then
				if ! nft -f - <<EOF
delete element $family $table_name $HOST_SET { $resolved_ip }
add element $family $table_name $HOST_SET { $resolved_ip timeout $HOST_TIMEOUT }
EOF
				then
					maintenance_failed=1
				fi
			elif ! nft add element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip timeout $HOST_TIMEOUT }"; then
				maintenance_failed=1
			fi
		done
	done <<EOF
$(host_set_targets)
EOF
	[ "$compatible_targets" -gt 0 ] || maintenance_failed=1
	[ "$maintenance_failed" -eq 0 ] || {
		echo 'wloc: unable to refresh the WLOC host set' >&2
		return 1
	}
	printf '%s\n' "$now" >"$STAMP" || return 1
}

refresh_hosts() {
	set_hosts "$@"
	rm -f "$STAMP" "$DNS_ATTEMPT_STAMP"
	resolve_hosts
}

apply_rules() {
	local port
	port="$1"
	shift
	set_hosts "$@"
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; return 1; }
	refresh_hosts "$@"
}

valid_ifname() {
	case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
	[ "${#1}" -le 15 ]
}

load_ap_lib() {
	[ "${WLOC_AP_LIB_LOADED:-0}" -eq 1 ] || . "$AP_LIB"
}

reconcile() {
	local port
	port="$1"
	shift
	set_hosts "$@"
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; return 1; }
	resolve_hosts || {
		echo 'wloc: host-set reconciliation failed' >&2
		return 1
	}
	sync_ingress_interfaces || {
		echo 'wloc: ingress-set reconciliation failed' >&2
		return 1
	}
}

collect_wloc_ingress() {
	local section enabled iface
	section="$1"
	config_get_bool enabled "$section" enabled 1
	[ "$enabled" -eq 1 ] || return 0
	config_get iface "$section" iface ''
	[ -n "$iface" ] || {
		WLOC_RESOLVE_ERROR="interface is missing from enabled rule $section"
		return 0
	}
	if ! wloc_ap_find_section_by_ifname "$iface" >/dev/null; then
		WLOC_RESOLVE_ERROR="cannot resolve configured interface \"$iface\""
		return 0
	fi
	# The rule stores the fixed wifi-iface name. Use it directly so startup
	# does not need to scan runtime interfaces or expand a bridge.
	valid_ifname "$iface" || {
		WLOC_RESOLVE_ERROR="invalid configured interface \"$iface\""
		return 0
	}
	case " $WLOC_INGRESS_INTERFACES " in
		*" $iface "*) ;;
		*) WLOC_INGRESS_INTERFACES="${WLOC_INGRESS_INTERFACES} $iface" ;;
	esac
}

sync_ingress_interfaces() {
	local interface interfaces family set set_dump
	WLOC_RESOLVE_ERROR=''
	WLOC_INGRESS_INTERFACES=''
	read -r family set <<EOF
$(active_ingress_set)
EOF
	# A custom ruleset may not use WLOC's optional interface set at all.
	[ -n "$family" ] && [ -n "$set" ] || return 0
	if ! set_dump="$(nft list set "$family" "$TABLE" "$set" 2>/dev/null)"; then
		echo "wloc: unable to inspect $family/$TABLE/$set" >&2
		return 1
	fi
	if ! printf '%s\n' "$set_dump" | grep -q 'type ifname' || \
		! printf '%s\n' "$set_dump" | grep -Eq 'flags timeout|^[[:space:]]*timeout[[:space:]]'; then
		echo "wloc: optional ingress set $family/$TABLE/$set has an incompatible type" >&2
		return 1
	fi
	load_ap_lib || return 1
	config_load wloc || return 1
	config_foreach collect_wloc_ingress wifi
	[ -z "$WLOC_RESOLVE_ERROR" ] || {
		echo "wloc: $WLOC_RESOLVE_ERROR; interface set was not changed" >&2
		return 1
	}
	interfaces="$WLOC_INGRESS_INTERFACES"
	{
		printf 'flush set %s %s %s\n' "$family" "$TABLE" "$set"
		for interface in $interfaces; do
			printf 'add element %s %s %s { "%s" timeout %s }\n' \
			"$family" "$TABLE" "$set" "$interface" "$INGRESS_INTERFACE_TIMEOUT"
		done
	} | nft -f - || {
		echo "wloc: unable to refresh $family/$TABLE/$set; custom rules were left unchanged" >&2
		return 1
	}
}

case "${1:-}" in
	apply)
		port="${2:-}"
		shift 2
		apply_rules "$port" "$@"
		;;
	reconcile)
		port="${2:-}"
		shift 2
		reconcile "$port" "$@"
		;;
	cleanup) cleanup;;
	status)
		nft list table inet "$TABLE" 2>/dev/null
		;;
	resolve-hosts)
		shift
		set_hosts "$@"
		resolve_hosts
		;;
	refresh-hosts)
		shift
		refresh_hosts "$@"
		;;
	*) echo 'usage: rules.sh {apply PORT|reconcile PORT|cleanup|status|resolve-hosts|refresh-hosts}' >&2; exit 2;;
esac
