#!/bin/sh
# Dedicated fail-open interception lifecycle for OpenWrt WLOC.

set -eu

TABLE=wloc
CLIENT_MAC_SET=target_clients_mac
AP_INTERFACE_SET=target_ap_interfaces
HOST_SET=apple_wloc_v4
DEFAULT_PRIORITY=-105
# REDIRECT needs conntrack/NAT state. Stay strictly after conntrack (-200),
# while moving ahead of the earliest detected transparent-proxy base chain.
MIN_SAFE_PRIORITY=-199
STAMP=/var/run/wloc/hosts.refreshed
ORDER_STATE=/var/run/wloc/order-conflict
PRIORITY_STATE=/var/run/wloc/prerouting.priority
PRIORITY_DETAILS=/var/run/wloc/prerouting.details
HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'
HOST_TIMEOUT=15m
DNS_SAMPLES=3

cleanup() {
	nft delete table inet "$TABLE" 2>/dev/null || true
	rm -f "$STAMP" "$ORDER_STATE" "$PRIORITY_STATE" "$PRIORITY_DETAILS"
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

resolve_hosts() {
	local now last addresses host resolved_ip sample
	[ -d "${STAMP%/*}" ] || mkdir -p "${STAMP%/*}"
	now="$(date +%s)"
	last="$(cat "$STAMP" 2>/dev/null || echo 0)"
	[ $((now - last)) -ge 60 ] || return 0
	addresses=''
	for host in $HOSTS; do
		sample=0
		while [ "$sample" -lt "$DNS_SAMPLES" ]; do
			# BusyBox nslookup prints the DNS server as an Address before the
			# answer Name. Parse only Address lines in the answer section.
			for resolved_ip in $(timeout 5 nslookup "$host" 2>/dev/null \
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
		# keep retrying resolution on every reconciliation until it recovers.
		nft list set inet "$TABLE" "$HOST_SET" 2>/dev/null \
			| grep -q 'elements = {' && return 0
		return 1
	fi
	# Keep a rolling address pool instead of flushing it on every DNS answer.
	# CDN answers and a client-facing proxy resolver can legitimately rotate
	# between refreshes. Renew current answers and let unseen ones age out.
	for resolved_ip in $addresses; do
		if nft get element inet "$TABLE" "$HOST_SET" "{ $resolved_ip }" >/dev/null 2>&1; then
			nft -f - <<EOF
delete element inet $TABLE $HOST_SET { $resolved_ip }
add element inet $TABLE $HOST_SET { $resolved_ip timeout $HOST_TIMEOUT }
EOF
		else
			nft add element inet "$TABLE" "$HOST_SET" "{ $resolved_ip timeout $HOST_TIMEOUT }"
		fi
	done
	printf '%s\n' "$now" >"$STAMP"
}

table_healthy() {
	awk \
		-v client_mac_set="$CLIENT_MAC_SET" \
		-v ap_interface_set="$AP_INTERFACE_SET" \
		-v host_set="$HOST_SET" '
		$1 == "set" {
			in_host = ($2 == host_set)
			if ($2 == client_mac_set) client_mac = 1
			if ($2 == ap_interface_set) ap_interface = 1
			if ($2 == host_set) host = 1
		}
		in_host && $1 == "elements" && $2 == "=" && $3 == "{" { host_elements = 1 }
		in_host && $1 == "}" { in_host = 0 }
		$1 == "chain" && $2 == "redirect_prerouting" { redirect_chain = 1 }
		END { exit !(client_mac && ap_interface && host && host_elements && redirect_chain) }
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
	nft list chain inet "$TABLE" redirect_prerouting 2>/dev/null | awk '
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

check_prerouting_order() {
	local own_priority analysis record numeric family table_name chain priority_text verdict via relation order_conflict order_unknown proxy_seen
	[ -d "${ORDER_STATE%/*}" ] || mkdir -p "${ORDER_STATE%/*}"
	own_priority="$(read_wloc_priority)"
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
	logger -t wlocd "ORDER: WLOC table=$TABLE chain=redirect_prerouting numeric=$own_priority verdict=REDIRECT stage=first" 2>/dev/null || true
	echo "wloc: ORDER: WLOC table=$TABLE chain=redirect_prerouting numeric=$own_priority verdict=REDIRECT stage=first" >&2
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
	return 0
}

rules_healthy() {
	local table_dump
	table_dump="$(nft list table inet "$TABLE" 2>/dev/null)" || return 1
	printf '%s\n' "$table_dump" | table_healthy && order_healthy
}

apply_rules() {
	local port priority
	port="$1"
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; exit 1; }
	priority="$(choose_wloc_priority)" || {
		# Never retain an older interception chain when its precedence can no
		# longer be proven against the current ruleset.
		cleanup
		exit 1
	}
	cleanup
	trap cleanup EXIT INT TERM HUP
	nft -f - <<EOF
table inet $TABLE {
	set $CLIENT_MAC_SET {
		type ether_addr
		flags timeout
		timeout 30s
	}
	set $AP_INTERFACE_SET {
		type ifname
		flags timeout
		timeout 30s
	}
	set $HOST_SET {
		type ipv4_addr
		flags timeout
		timeout $HOST_TIMEOUT
	}
	chain redirect_prerouting {
		# The priority is selected from the live ruleset so this narrowly scoped
		# REDIRECT runs before every detected IPv4 REDIRECT/TPROXY ingress path.
		type nat hook prerouting priority $priority; policy accept;
		ether saddr @$CLIENT_MAC_SET ip daddr @$HOST_SET meta l4proto tcp tcp dport 443 counter redirect to :$port comment "wloc owned MAC redirect"
		iifname @$AP_INTERFACE_SET ip daddr @$HOST_SET meta l4proto tcp tcp dport 443 counter redirect to :$port comment "wloc owned AP redirect"
	}
}
EOF
	[ -d "${PRIORITY_STATE%/*}" ] || mkdir -p "${PRIORITY_STATE%/*}"
	printf '%s\n' "$priority" >"$PRIORITY_STATE"
	write_priority_details || true
	check_prerouting_order
	trap - EXIT INT TERM HUP
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
	local selector value macs bssids all_wireless interfaces interface
	macs=''
	bssids=''
	all_wireless=0
	interfaces=''
	[ "$#" -gt 0 ] || { echo 'wloc: no capture selectors' >&2; exit 1; }
	for selector in "$@"; do
		case "$selector" in
			mac:*)
				value="$(normalize_mac "${selector#mac:}")"
				valid_mac "$value" || { echo 'wloc: invalid MAC capture selector' >&2; exit 1; }
				case " $macs " in *" $value "*) :;; *) macs="$macs $value";; esac
				;;
			bssid:*)
				value="$(normalize_mac "${selector#bssid:}")"
				valid_mac "$value" || { echo 'wloc: invalid BSSID capture selector' >&2; exit 1; }
				case " $bssids " in *" $value "*) :;; *) bssids="$bssids $value";; esac
				;;
			wireless:any) all_wireless=1;;
			*) echo 'wloc: invalid capture selector' >&2; exit 1;;
		esac
	done
	resolve_hosts || { echo 'wloc: Apple WLOC DNS resolution failed' >&2; exit 1; }
	if [ "$all_wireless" -eq 1 ]; then
		interfaces="$(hostapd_interfaces any)"
	else
		for value in $bssids; do
			interfaces="${interfaces}
$(hostapd_interfaces "$value")"
		done
	fi
	# Flush and repopulate both candidate sets atomically. BSSID selection is
	# converted to its hostapd ingress interface; Rust still performs the final
	# live BSSID check in ordered rule matching.
	{
		echo "flush set inet $TABLE $CLIENT_MAC_SET"
		echo "flush set inet $TABLE $AP_INTERFACE_SET"
		for value in $macs; do
			echo "add element inet $TABLE $CLIENT_MAC_SET { $value timeout 30s }"
		done
		printf '%s\n' "$interfaces" | while read -r interface; do
			valid_interface "$interface" || continue
			echo "add element inet $TABLE $AP_INTERFACE_SET { \"$interface\" timeout 30s }"
		done
	} | nft -f -
}

reconcile() {
	local port
	port="$1"
	shift
	valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; exit 1; }
	# Firewall reloads and competing rule managers may remove the runtime-only
	# table or add an earlier proxy hook. Recreate WLOC at a newly verified
	# priority before renewing its short-lived selectors.
	rules_healthy || apply_rules "$port"
	lease "$@"
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
	*) echo 'usage: rules.sh {apply PORT|lease CAPTURE_SELECTOR...|reconcile PORT CAPTURE_SELECTOR...|cleanup|status|check-order}' >&2; exit 2;;
esac
