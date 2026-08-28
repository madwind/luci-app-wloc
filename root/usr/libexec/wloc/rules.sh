#!/bin/sh
# Dedicated fail-open interception lifecycle for OpenWrt WLOC.

set -eu

TABLE=wloc
INGRESS_SET=target_ingress_interfaces
HOST_SET=apple_wloc_v4
# The RPC apply transaction updates this snapshot only after nft succeeds, so
# DNS maintenance follows the active configuration rather than unsaved state.
CUSTOM_FIREWALL=/var/run/wloc/firewall.applied.nft
STAMP=/var/run/wloc/hosts.refreshed
DNS_ATTEMPT_STAMP=/var/run/wloc/hosts.attempted
ORDER_STATE=/var/run/wloc/order-conflict
ORDER_CHECK_STAMP=/var/run/wloc/order-checked
PRIORITY_STATE=/var/run/wloc/prerouting.priority
PRIORITY_DETAILS=/var/run/wloc/prerouting.details
AP_LIB=${WLOC_AP_LIB_PATH:-/usr/libexec/wloc/ap-lib.sh}
DEFAULT_HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'
HOSTS="$DEFAULT_HOSTS"
HOST_TIMEOUT=15m
DNS_SAMPLES=1
DNS_REFRESH_SECONDS=300
DNS_RETRY_SECONDS=60
ORDER_CHECK_SECONDS=60
INGRESS_INTERFACE_TIMEOUT=30s

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

cleanup() {
	clear_ingress_interfaces || true
	rm -f "$STAMP" "$DNS_ATTEMPT_STAMP" "$ORDER_STATE" "$ORDER_CHECK_STAMP" \
		"$PRIORITY_STATE" "$PRIORITY_DETAILS"
}

valid_port() {
	case "$1" in ''|*[!0-9]*) return 1;; esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4() {
	case "$1" in ''|*[!0-9.]*) return 1;; esac
	oldifs=$IFS; IFS=.; set -- $1; IFS=$oldifs
	[ "$#" -eq 4 ] || return 1
	for octet in "$@"; do [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] || return 1; done
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
		nft list set "$family" "$table_name" "$HOST_SET" >/dev/null 2>&1 && return 0
	done <<EOF
$(host_set_targets)
EOF
	return 1
}

resolve_hosts() {
	local now last attempt addresses host resolved_ip sample family table_name set_dump
	# Do not perform DNS work when neither the automatic table nor a custom
	# table currently exposes the fixed managed set.
	host_set_available || return 0
	[ -d "${STAMP%/*}" ] || mkdir -p "${STAMP%/*}"
	now="$(date +%s)"
	last="$(cat "$STAMP" 2>/dev/null || echo 0)"
	[ $((now - last)) -ge "$DNS_REFRESH_SECONDS" ] || return 0
	attempt="$(cat "$DNS_ATTEMPT_STAMP" 2>/dev/null || echo 0)"
	if [ $((now - attempt)) -lt "$DNS_RETRY_SECONDS" ]; then
		return 0
	fi
	printf '%s\n' "$now" >"$DNS_ATTEMPT_STAMP"
	addresses=''
	for host in $HOSTS; do
		sample=0
		while [ "$sample" -lt "$DNS_SAMPLES" ]; do
			# BusyBox nslookup prints the DNS server as an Address before the
			# answer Name. Parse only Address lines in the answer section.
			# Use the local resolver explicitly because some resolv.conf files
			# contain inline comments that break BusyBox nslookup's server parsing.
			for resolved_ip in $(nslookup "$host" 127.0.0.1 2>/dev/null \
				| sed -n '/^Name:[[:space:]]/,$ s/^Address[^:]*:[[:space:]]*\([0-9][0-9.]*\).*$/\1/p'); do
				valid_ipv4 "$resolved_ip" || continue
				case " $addresses " in
					*" $resolved_ip "*) :;;
					*) addresses="$addresses $resolved_ip";;
				esac
			done
			sample=$((sample + 1))
		done
	done
	if [ -z "$addresses" ]; then
		# A short DNS outage must not reject otherwise valid custom rules. Existing
		# CDN addresses keep their own timeout and are left untouched.
		return 0
	fi
	# Keep a rolling address pool instead of flushing it on every DNS answer.
	# CDN answers and a client-facing proxy resolver can legitimately rotate
	# between refreshes. Renew current answers and let unseen ones age out.
	while read -r family table_name; do
		[ -n "$family" ] || continue
		# A configured custom table becomes a DNS target only when it declares
		# its own compatible ipv4_addr set named apple_wloc_v4. An unrelated set
		# with the same name is valid nftables and is simply not maintained.
		set_dump="$(nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null)" || continue
		printf '%s\n' "$set_dump" | grep -q 'type ipv4_addr' \
			&& printf '%s\n' "$set_dump" | grep -Eq 'flags timeout|^[[:space:]]*timeout[[:space:]]' \
			|| continue
		for resolved_ip in $addresses; do
			if nft get element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip }" >/dev/null 2>&1; then
				nft -f - <<EOF || true
delete element $family $table_name $HOST_SET { $resolved_ip }
add element $family $table_name $HOST_SET { $resolved_ip timeout $HOST_TIMEOUT }
EOF
			else
				nft add element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip timeout $HOST_TIMEOUT }" || true
			fi
		done
	done <<EOF
$(host_set_targets)
EOF
	printf '%s\n' "$now" >"$STAMP"
}

refresh_hosts() {
	set_hosts "$@"
	rm -f "$STAMP" "$DNS_ATTEMPT_STAMP"
	resolve_hosts
}

analyze_prerouting_proxies() {
	local ruleset
	ruleset="$(nft -a list ruleset 2>/dev/null)" || return 1
	[ -n "$ruleset" ] || return 1
	printf '%s\n' "$ruleset" | awk -v own_family=inet -v own_table="$TABLE" '
		function priority_value(raw, parts, count, base, value, delta) {
			gsub(/[;]/, "", raw)
			gsub(/[[:space:]]+/, " ", raw)
			sub(/^ /, "", raw)
			sub(/ $/, "", raw)
			count = split(raw, parts, " ")
			base = parts[1]
			if (base ~ /^-?[0-9]+$/) value = base + 0
			else if (base == "raw") value = -300
			else if (base == "conntrack") value = -200
			else if (base == "mangle") value = -150
			else if (base == "dstnat") value = -100
			else if (base == "filter") value = 0
			else if (base == "security") value = 50
			else if (base == "srcnat") value = 100
			else return ""
			if (count >= 3 && (parts[2] == "+" || parts[2] == "-") && parts[3] ~ /^[0-9]+$/) {
				delta = parts[3] + 0
				value = parts[2] == "+" ? value + delta : value - delta
			}
			return value
		}
		function key(family, table_name, chain_name) {
			return family SUBSEP table_name SUBSEP chain_name
		}
		/^[[:space:]]*table[[:space:]]/ {
			family_name = $2
			table_name = $3
			sub(/\{.*/, "", table_name)
			chain_active = 0
			next
		}
		/^[[:space:]]*chain[[:space:]]/ {
			chain_name = $2
			sub(/\{.*/, "", chain_name)
			current = key(family_name, table_name, chain_name)
			chain_family[current] = family_name
			chain_table[current] = table_name
			chain_label[current] = chain_name
			chains[current] = 1
			chain_count++
			chain_active = 1
			next
		}
		/^[[:space:]]*}[[:space:]]*$/ {
			chain_active = 0
			next
		}
		chain_active {
			rule_text = $0
			sub(/[[:space:]]+comment[[:space:]]+".*/, "", rule_text)
			sub(/[[:space:]]+# handle[[:space:]].*/, "", rule_text)
			if (rule_text ~ /hook[[:space:]]+prerouting/) {
				priority_text = rule_text
				sub(/^.*priority[[:space:]]+/, "", priority_text)
				sub(/;.*/, "", priority_text)
				gsub(/[[:space:]]+$/, "", priority_text)
				base_chain[current] = 1
				base_priority_text[current] = priority_text
				base_priority[current] = priority_value(priority_text)
			}
			if (rule_text ~ /(^|[[:space:]])redirect([[:space:]]|$)/)
				direct_redirect[current] = 1
			if (rule_text ~ /(^|[[:space:]])tproxy([[:space:]]|$)/)
				direct_tproxy[current] = 1
			n = split(rule_text, fields, /[[:space:]]+/)
			for (i = 1; i < n; i++) {
				if (fields[i] == "jump" || fields[i] == "goto") {
					edge_count++
					edge_source[edge_count] = current
					edge_target[edge_count] = key(family_name, table_name, fields[i + 1])
				}
			}
		}
		END {
			for (chain in chains) {
				reaches_redirect[chain] = direct_redirect[chain]
				reaches_tproxy[chain] = direct_tproxy[chain]
			}
			for (pass = 1; pass <= chain_count; pass++) {
				changed = 0
				for (edge = 1; edge <= edge_count; edge++) {
					source = edge_source[edge]
					target = edge_target[edge]
					if (reaches_redirect[target] && !reaches_redirect[source]) {
						reaches_redirect[source] = 1
						changed = 1
					}
					if (reaches_tproxy[target] && !reaches_tproxy[source]) {
						reaches_tproxy[source] = 1
						changed = 1
					}
				}
				if (!changed) break
			}
			for (chain in base_chain) {
				if (chain_family[chain] == own_family && chain_table[chain] == own_table)
					continue
				# Only IPv4-capable hooks share the path used by WLOC. ip6,
				# bridge, arp and netdev priorities are different hook domains.
				if (chain_family[chain] != "ip" && chain_family[chain] != "inet")
					continue
				if (!reaches_redirect[chain] && !reaches_tproxy[chain])
					continue
				verdict = reaches_redirect[chain] && reaches_tproxy[chain] ? "REDIRECT/TPROXY" : (reaches_redirect[chain] ? "REDIRECT" : "TPROXY")
				via = direct_redirect[chain] || direct_tproxy[chain] ? "direct" : "jump"
				numeric = base_priority[chain]
				if (numeric == "") numeric = "unknown"
				printf "PROXY|%s|%s|%s|%s|%s|%s|%s\n", numeric, chain_family[chain], chain_table[chain], chain_label[chain], base_priority_text[chain], verdict, via
			}
		}
	' | sort -t '|' -k2,2n -k3,3 -k4,4 -k5,5
}

write_priority_details() {
	local analysis
	analysis="$(analyze_prerouting_proxies)" || return 1
	[ -d "${PRIORITY_DETAILS%/*}" ] || mkdir -p "${PRIORITY_DETAILS%/*}"
	printf '%s\n' "$analysis" | awk -F'|' '
		$1 == "PROXY" {
			if (found++) printf ", "
			printf "%s (numeric %s)", $5, $2
		}
		END { if (!found) printf "none"; printf "\n" }
	' >"$PRIORITY_DETAILS"
}

read_wloc_priority() {
	{
		nft list chain inet "$TABLE" mark_prerouting 2>/dev/null \
			|| nft list chain inet "$TABLE" redirect_prerouting 2>/dev/null
	} | awk '
		function priority_value(raw, parts, count, base, value, delta) {
			gsub(/[;]/, "", raw); gsub(/[[:space:]]+/, " ", raw); sub(/^ /, "", raw); sub(/ $/, "", raw)
			count = split(raw, parts, " "); base = parts[1]
			if (base ~ /^-?[0-9]+$/) value = base + 0
			else if (base == "raw") value = -300
			else if (base == "conntrack") value = -200
			else if (base == "mangle") value = -150
			else if (base == "dstnat") value = -100
			else if (base == "filter") value = 0
			else if (base == "security") value = 50
			else if (base == "srcnat") value = 100
			else return ""
			if (count >= 3 && (parts[2] == "+" || parts[2] == "-") && parts[3] ~ /^[0-9]+$/) {
				delta = parts[3] + 0; value = parts[2] == "+" ? value + delta : value - delta
			}
			return value
		}
		/hook[[:space:]]+prerouting/ {
			text = $0; sub(/^.*priority[[:space:]]+/, "", text); sub(/;.*/, "", text)
			print priority_value(text); exit
		}
	'
}

read_wloc_chain() {
	nft list chain inet "$TABLE" mark_prerouting >/dev/null 2>&1 \
		&& printf '%s' mark_prerouting || printf '%s' redirect_prerouting
}

order_check_due() {
	local now last
	[ "$(cat "$ORDER_STATE" 2>/dev/null || true)" = 0 ] || return 0
	now="$(date +%s)"
	last="$(cat "$ORDER_CHECK_STAMP" 2>/dev/null || echo 0)"
	[ $((now - last)) -ge "$ORDER_CHECK_SECONDS" ]
}

mark_order_checked() {
	date +%s >"$ORDER_CHECK_STAMP"
}

check_prerouting_order() {
	local own_priority own_chain analysis record numeric family table_name chain priority_text verdict via relation order_conflict order_unknown proxy_seen
	[ -d "${ORDER_STATE%/*}" ] || mkdir -p "${ORDER_STATE%/*}"
	own_priority="$(read_wloc_priority)"
	own_chain="$(read_wloc_chain)"
	analysis="$(analyze_prerouting_proxies)" || {
		printf '%s\n' unknown >"$ORDER_STATE"
		logger -t wlocd 'WARNING: unable to inspect nftables ruleset; WLOC prerouting order could not be confirmed' 2>/dev/null || true
		echo 'wloc: WARNING: unable to inspect nftables ruleset; WLOC prerouting order could not be confirmed' >&2
		return 1
	}
	case "$own_priority" in
		''|*[!0-9-]*)
			printf '%s\n' unknown >"$ORDER_STATE"
			echo 'wloc: WARNING: WLOC prerouting priority could not be read' >&2
			return 1
			;;
	esac

	printf '%s\n' "$own_priority" >"$PRIORITY_STATE"
  write_priority_details || true

	logger -t wlocd "ORDER: WLOC table=$TABLE chain=$own_chain numeric=$own_priority stage=first" 2>/dev/null || true
	echo "wloc: ORDER: WLOC table=$TABLE chain=$own_chain numeric=$own_priority stage=first" >&2
	order_conflict=0
	order_unknown=0
	proxy_seen=0
	while IFS='|' read -r record numeric family table_name chain priority_text verdict via; do
		[ "$record" = PROXY ] || continue
		proxy_seen=1
		if [ "$numeric" = unknown ]; then
			relation=unknown
			order_unknown=1
		elif [ "$numeric" -gt "$own_priority" ]; then
			relation=after_wloc
		elif [ "$numeric" -eq "$own_priority" ]; then
			relation=same_as_wloc
			order_conflict=1
		else
			relation=before_wloc
			order_conflict=1
		fi
		logger -t wlocd "ORDER: PROXY family=$family table=$table_name chain=$chain priority=$priority_text numeric=$numeric verdict=$verdict via=$via relation=$relation" 2>/dev/null || true
		echo "wloc: ORDER: PROXY family=$family table=$table_name chain=$chain priority=$priority_text numeric=$numeric verdict=$verdict via=$via relation=$relation" >&2
	done <<EOF
$analysis
EOF
	[ "$proxy_seen" -eq 1 ] || {
		logger -t wlocd 'ORDER: PROXY none relation=none' 2>/dev/null || true
		echo 'wloc: ORDER: PROXY none relation=none' >&2
	}
	if [ "$order_conflict" -eq 1 ]; then
		printf '%s\n' 1 >"$ORDER_STATE"
		logger -t wlocd 'WARNING: a transparent-proxy prerouting chain runs before or with WLOC' 2>/dev/null || true
		echo 'wloc: WARNING: a transparent-proxy prerouting chain runs before or with WLOC' >&2
		return 1
	elif [ "$order_unknown" -eq 1 ]; then
		printf '%s\n' unknown >"$ORDER_STATE"
		logger -t wlocd 'WARNING: a transparent-proxy prerouting priority could not be compared with WLOC' 2>/dev/null || true
		echo 'wloc: WARNING: a transparent-proxy prerouting priority could not be compared with WLOC' >&2
		return 1
	else
		printf '%s\n' 0 >"$ORDER_STATE"
	fi
	mark_order_checked
	return 0
}

apply_rules() {
	local port
	port="$1"
	shift
	set_hosts "$@"
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; return 1; }
	# The editor owns the complete nftables program. WLOC only attempts to
	# refresh its documented dynamic set when that set is present.
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
	resolve_hosts
	sync_ingress_interfaces
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
	# The rule already stores the fixed wifi-iface name. Use it directly so
	# startup does not need to scan runtime interfaces or expand a bridge.
	valid_ifname "$iface" || {
		WLOC_RESOLVE_ERROR="invalid configured interface \"$iface\""
		return 0
	}
	case " $WLOC_INGRESS_INTERFACES " in
		*" $iface "*) ;;
		*) WLOC_INGRESS_INTERFACES="$WLOC_INGRESS_INTERFACES $iface" ;;
	esac
}

sync_ingress_interfaces() {
	local interface interfaces family set
	WLOC_RESOLVE_ERROR=''
	WLOC_INGRESS_INTERFACES=''
	read -r family set <<EOF
$(active_ingress_set)
EOF
	# A custom ruleset may not use WLOC's optional interface set at all.
	# Leave it untouched and consider synchronization successful in that case.
	[ -n "$family" ] && [ -n "$set" ] || return 0
	if ! nft list set "$family" "$TABLE" "$set" 2>/dev/null \
		| grep -q 'type ifname'; then
		return 0
	fi
	if ! nft list set "$family" "$TABLE" "$set" 2>/dev/null \
		| grep -Eq 'flags timeout|^[[:space:]]*timeout[[:space:]]'; then
		return 0
	fi
	load_ap_lib || return 0
	config_load wloc || return 0
	config_foreach collect_wloc_ingress wifi
	[ -z "$WLOC_RESOLVE_ERROR" ] || {
		echo "wloc: warning: $WLOC_RESOLVE_ERROR; interface set was not changed" >&2
		return 0
	}
	interfaces="$WLOC_INGRESS_INTERFACES"

	{
		printf 'flush set %s %s %s\n' \
			"$family" "$TABLE" "$set"
		for interface in $interfaces; do
			printf 'add element %s %s %s { "%s" timeout %s }\n' \
			"$family" "$TABLE" "$set" "$interface" "$INGRESS_INTERFACE_TIMEOUT"
		done
	} | nft -f - || {
		echo "wloc: warning: unable to refresh $family/$TABLE/$set; custom rules were left unchanged" >&2
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
