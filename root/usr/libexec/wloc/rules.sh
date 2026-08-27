#!/bin/sh
# Dedicated fail-open interception lifecycle for OpenWrt WLOC.

set -eu

TABLE=wloc
AP_INTERFACE_SET=target_ap_interfaces
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
HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'
HOST_TIMEOUT=15m
DNS_SAMPLES=1
DNS_REFRESH_SECONDS=300
DNS_RETRY_SECONDS=60
ORDER_CHECK_SECONDS=60

cleanup() {
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

valid_mac() {
	local first_octet
	case "$1" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
		*) return 1;;
	esac
	first_octet="${1%%:*}"
	case "$first_octet" in
		[0-9A-Fa-f][13579BbDdFf]) return 1;;
	esac
	[ "$1" != '00:00:00:00:00:00' ]
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
					} else if (words[first] == "set" && words[first + 1] == host_set \
						&& family != "" && table_name != "") {
						print family, table_name
					}
				}
			}
		' "$CUSTOM_FIREWALL"
	} | awk '!seen[$0]++'
}

host_set_populated() {
	local family table_name
	while read -r family table_name; do
		[ -n "$family" ] || continue
		nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null \
			| grep -q 'elements = {' && return 0
	done <<EOF
$(host_set_targets)
EOF
	return 1
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
		host_set_populated
		return $?
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
		# A short DNS outage must not tear down otherwise valid interception.
		# Existing CDN addresses have their own timeout and remain safe to use;
		# retry on the bounded failure cadence until it recovers.
		host_set_populated && return 0
		return 1
	fi
	# Keep a rolling address pool instead of flushing it on every DNS answer.
	# CDN answers and a client-facing proxy resolver can legitimately rotate
	# between refreshes. Renew current answers and let unseen ones age out.
	while read -r family table_name; do
		[ -n "$family" ] || continue
		# A configured custom table becomes a DNS target only when it declares
		# its own ipv4_addr set named apple_wloc_v4.
		set_dump="$(nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null)" || continue
		printf '%s\n' "$set_dump" | grep -q 'type ipv4_addr' \
			&& printf '%s\n' "$set_dump" | grep -Eq 'flags timeout|^[[:space:]]*timeout[[:space:]]' || {
			echo "wloc: $family/$table_name set $HOST_SET must use type ipv4_addr and flags timeout" >&2
			return 1
		}
		for resolved_ip in $addresses; do
			if nft get element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip }" >/dev/null 2>&1; then
				nft -f - <<EOF
delete element $family $table_name $HOST_SET { $resolved_ip }
add element $family $table_name $HOST_SET { $resolved_ip timeout $HOST_TIMEOUT }
EOF
			else
				nft add element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip timeout $HOST_TIMEOUT }"
			fi
		done
	done <<EOF
$(host_set_targets)
EOF
	printf '%s\n' "$now" >"$STAMP"
}

refresh_hosts() {
	rm -f "$STAMP" "$DNS_ATTEMPT_STAMP"
	resolve_hosts
}

table_healthy() {
	awk \
		-v ap_interface_set="$AP_INTERFACE_SET" \
		-v host_set="$HOST_SET" \
		-v port="$1" '
		$1 == "set" {
			current_set = $2
			in_host = ($2 == host_set)
			if ($2 == ap_interface_set) ap_interface = 1
			if ($2 == host_set) host = 1
		}
		current_set == ap_interface_set && $1 == "type" && $2 == "ifname" { ap_type = 1 }
		current_set == host_set && $1 == "type" && $2 == "ipv4_addr" { host_type = 1 }
		current_set == ap_interface_set && $1 == "flags" && $2 == "timeout" { ap_timeout = 1 }
		current_set == host_set && $1 == "flags" && $2 == "timeout" { host_timeout = 1 }
		in_host && $1 == "elements" && $2 == "=" && $3 == "{" { host_elements = 1 }
		$1 == "chain" {
			current_set = ""
			in_host = 0
			in_redirect = ($2 == "redirect_prerouting")
			if (in_redirect) redirect_chain = 1
		}
		in_redirect && /type[[:space:]]+nat[[:space:]]+hook[[:space:]]+prerouting/ { redirect_hook = 1 }
		in_redirect && index($0, "iifname @" ap_interface_set) \
			&& index($0, "ip daddr @" host_set) \
			&& index($0, "tcp dport 443") \
			&& index($0, "redirect to :" port) \
			&& index($0, "comment \"wloc owned AP redirect\"") { ap_redirect = 1 }
		END {
			exit !(ap_interface && ap_type && ap_timeout \
				&& host && host_type && host_timeout && redirect_chain \
				&& redirect_hook && ap_redirect)
		}
	'
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

choose_wloc_priority() {
	local analysis numeric family table_name chain priority_text verdict via earliest selected unknown
	analysis="$(analyze_prerouting_proxies)" || {
		echo 'wloc: unable to inspect nftables prerouting order' >&2
		return 1
	}
	earliest=''
	unknown=0
	while IFS='|' read -r record numeric family table_name chain priority_text verdict via; do
		[ "$record" = PROXY ] || continue
		if [ "$numeric" = unknown ]; then
			unknown=1
			continue
		fi
		[ -n "$earliest" ] && [ "$numeric" -ge "$earliest" ] || earliest="$numeric"
	done <<EOF
$analysis
EOF
	[ "$unknown" -eq 0 ] || {
		echo 'wloc: a transparent-proxy prerouting priority could not be parsed' >&2
		return 1
	}
	selected="$DEFAULT_PRIORITY"
	if [ -n "$earliest" ] && [ "$earliest" -le "$selected" ]; then
		selected=$((earliest - 1))
	fi
	[ "$selected" -ge "$MIN_SAFE_PRIORITY" ] || {
		echo "wloc: earliest transparent-proxy priority $earliest leaves no safe post-conntrack priority" >&2
		return 1
	}
	printf '%s' "$selected"
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

order_healthy() {
	local own_priority analysis record numeric family table_name chain priority_text verdict via
	own_priority="$(read_wloc_priority)"
	case "$own_priority" in ''|*[!0-9-]*) return 1;; esac
	analysis="$(analyze_prerouting_proxies)" || return 1
	while IFS='|' read -r record numeric family table_name chain priority_text verdict via; do
		[ "$record" = PROXY ] || continue
		case "$numeric" in unknown|''|*[!0-9-]*) return 1;; esac
		[ "$own_priority" -lt "$numeric" ] || return 1
	done <<EOF
$analysis
EOF
	return 0
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

rules_healthy() {
	local port="$1" table_dump
	table_dump="$(nft list table inet "$TABLE" 2>/dev/null)" || return 1
	printf '%s\n' "$table_dump" | table_healthy "$port" || return 1
	order_check_due || return 0
	order_healthy || return 1
	mark_order_checked
}

apply_rules() {
	local port
	port="$1"
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; exit 1; }
	nft list table inet "$TABLE" >/dev/null 2>&1 || {
		echo 'wloc: table inet wloc is not loaded; save and apply it in the nftables editor' >&2
		return 1
	}
	refresh_hosts
	check_prerouting_order || true
}

valid_interface() {
	case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
	[ "${#1}" -le 15 ]
}

normalize_mac() {
	awk -v value="$1" 'BEGIN { print tolower(value) }'
}

hostapd_interfaces() {
	local wanted object status bssid interface
	wanted="$1"
	for object in $(ubus -S -t 3 list 'hostapd.*' 2>/dev/null || true); do
		case "$object" in hostapd.*) :;; *) continue;; esac
		status="$(ubus -S -t 3 call "$object" get_status '{}' 2>/dev/null || true)"
		[ -n "$status" ] || continue
		bssid="$(printf '%s\n' "$status" | jsonfilter -e '@.bssid' 2>/dev/null || true)"
		bssid="$(normalize_mac "$bssid")"
		[ "$wanted" = any ] || [ "$bssid" = "$wanted" ] || continue
		interface="$(printf '%s\n' "$status" | jsonfilter -e '@.interface' 2>/dev/null || true)"
		[ -n "$interface" ] || interface="$(printf '%s\n' "$status" | jsonfilter -e '@.ifname' 2>/dev/null || true)"
		[ -n "$interface" ] || interface="${object#hostapd.}"
		valid_interface "$interface" && printf '%s\n' "$interface"
	done
}

lease() {
	resolve_hosts || { echo 'wloc: Apple WLOC DNS resolution failed' >&2; exit 1; }
}

reconcile() {
	local port
	port="$1"
	shift
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; exit 1; }
	nft list table inet "$TABLE" >/dev/null 2>&1 || return 1
	resolve_hosts
	if order_check_due; then check_prerouting_order || true; fi
}

case "${1:-}" in
	apply) apply_rules "${2:-}";;
	lease)
		shift
		lease "$@"
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
	check-order) check_prerouting_order;;
	resolve-hosts) resolve_hosts;;
	refresh-hosts) refresh_hosts;;
	*) echo 'usage: rules.sh {apply PORT|lease|reconcile PORT|cleanup|status|check-order|resolve-hosts|refresh-hosts}' >&2; exit 2;;
esac
