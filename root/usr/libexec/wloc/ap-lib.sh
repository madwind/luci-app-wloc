#!/bin/sh

# Shared SSID-based access-point resolver.  A WLOC rule stores only the exact
# configured SSID; every other AP attribute is discovered when it is needed.

[ "${WLOC_AP_LIB_LOADED:-0}" -eq 1 ] && return 0 2>/dev/null || true
WLOC_AP_LIB_LOADED=1

. "${WLOC_LIB_FUNCTIONS:-/lib/functions.sh}"
[ -r /usr/share/libubox/jshn.sh ] && . /usr/share/libubox/jshn.sh

wloc_ap_valid_section() {
	case "$1" in
		''|*[!A-Za-z0-9_-]*) return 1;;
	esac
}

wloc_ap_valid_network() {
	case "$1" in
		''|*[!A-Za-z0-9_.-]*) return 1;;
	esac
}

wloc_ap_valid_ifname() {
	case "$1" in
		''|*[!A-Za-z0-9_.-]*) return 1;;
	esac
	[ "${#1}" -le 15 ]
}

wloc_ap_collect_section_by_ssid() {
	local section mode candidate
	section="$1"
	config_get mode "$section" mode ap
	case "$mode" in
		ap|ap-wds) ;;
		*) return 0;;
	esac
	config_get candidate "$section" ssid ''
	[ -n "$candidate" ] && [ "$candidate" = "$WLOC_AP_WANTED_SSID" ] &&
		printf '%s\n' "$section"
}

wloc_ap_find_sections_by_ssid() {
	WLOC_AP_WANTED_SSID="$1"
	[ -n "$WLOC_AP_WANTED_SSID" ] || return 0
	config_load wireless || return 1
	config_foreach wloc_ap_collect_section_by_ssid wifi-iface
}

wloc_ap_find_section_by_ssid() {
	local ssid="$1" section count
	count=0
	section=''
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		count=$((count + 1))
		section="$candidate"
	done <<EOF
$(wloc_ap_find_sections_by_ssid "$ssid")
EOF
	case "$count" in
		0)
			echo "SSID \"$ssid\" was not found in wireless configuration" >&2
			return 1
			;;
		1) printf '%s\n' "$section"; return 0;;
		*)
			echo "SSID \"$ssid\" matches multiple wireless interfaces" >&2
			return 2
			;;
	esac
}

wloc_ap_get_ssid() {
	local section="$1" ssid
	wloc_ap_valid_section "$section" || return 1
	config_load wireless || return 1
	config_get ssid "$section" ssid ''
	[ -n "$ssid" ] || return 1
	printf '%s\n' "$ssid"
}

wloc_ap_get_network() {
	local section="$1" network
	wloc_ap_valid_section "$section" || return 1
	config_load wireless || return 1
	config_get network "$section" network ''
	wloc_ap_valid_network "$network" || return 1
	printf '%s\n' "$network"
}

wloc_ap_json_value() (
	local data="$1" key="$2" value
	[ -n "$data" ] || return 1
	type json_load >/dev/null 2>&1 || return 1
	json_load "$data" 2>/dev/null || return 1
	json_get_var value "$key"
	[ -n "$value" ] || return 1
	printf '%s\n' "$value"
)

wloc_ap_get_network_device() {
	local network="$1" status device
	wloc_ap_valid_network "$network" || return 1
	status="$(ubus -S -t 3 call "network.interface.$network" status 2>/dev/null || true)"
	device="$(wloc_ap_json_value "$status" device 2>/dev/null || true)"
	[ -n "$device" ] || device="$(wloc_ap_json_value "$status" l3_device 2>/dev/null || true)"
	if wloc_ap_valid_ifname "$device"; then
		printf '%s\n' "$device"
		return 0
	fi
	device="$(uci -q get "network.$network.device" 2>/dev/null || true)"
	[ -n "$device" ] || device="$(uci -q get "network.$network.ifname" 2>/dev/null || true)"
	wloc_ap_valid_ifname "$device" || return 1
	printf '%s\n' "$device"
}

# Returns the current runtime ifname for a configured wireless section.  An
# offline AP simply returns no value; that is not a configuration failure.
wloc_ap_get_runtime_ifname() {
	local wanted="$1" status radio index section ifname radio_keys interface_keys
	wloc_ap_valid_section "$wanted" || return 1
	type json_load >/dev/null 2>&1 || return 1
	status="$(ubus -S -t 3 call network.wireless status 2>/dev/null || true)"
	[ -n "$status" ] || return 1
	json_load "$status" 2>/dev/null || return 1
	radio_keys=''
	json_get_keys radio_keys
	for radio in $radio_keys; do
		json_select "$radio" || continue
		json_select interfaces || { json_select ..; continue; }
		interface_keys=''
		json_get_keys interface_keys
		for index in $interface_keys; do
			json_select "$index" || continue
			section=''
			ifname=''
			json_get_var section section
			json_get_var ifname ifname
			if [ "$section" = "$wanted" ] && wloc_ap_valid_ifname "$ifname"; then
				printf '%s\n' "$ifname"
				return 0
			fi
			json_select ..
		done
		json_select ..
		json_select ..
	done
	return 1
}

wloc_ap_get_hostapd_status() {
	local ifname="$1"
	wloc_ap_valid_ifname "$ifname" || return 1
	ubus -S -t 3 call "hostapd.$ifname" get_status '{}' 2>/dev/null
}
