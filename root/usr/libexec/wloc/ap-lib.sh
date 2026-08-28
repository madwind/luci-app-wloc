#!/bin/sh

# Shared fixed-interface access-point resolver. WLOC rules store the exact
# configured interface name from a wifi-iface option ifname.

[ "${WLOC_AP_LIB_LOADED:-0}" -eq 1 ] && return 0 2>/dev/null || true
WLOC_AP_LIB_LOADED=1

# OpenWrt's helper reads this installer-only variable directly. Keep runtime
# callers safe when strict shell mode is enabled by the caller.
IPKG_INSTROOT=${IPKG_INSTROOT:-}
CONFIG_LIST_STATE=${CONFIG_LIST_STATE:-}
NO_CALLBACK=${NO_CALLBACK:-}
. "${WLOC_LIB_FUNCTIONS:-/lib/functions.sh}"
[ -r /usr/share/libubox/jshn.sh ] && . /usr/share/libubox/jshn.sh

wloc_ap_valid_ifname() {
	case "$1" in
		''|*[!A-Za-z0-9_.-]*) return 1;;
	esac
	[ "${#1}" -le 15 ]
}

wloc_ap_collect_section_by_ifname() {
	local section mode ifname
	section="$1"
	config_get mode "$section" mode ap
	case "$mode" in
		ap|ap-wds) ;;
		*) return 0;;
	esac
	config_get ifname "$section" ifname ''
	[ "$ifname" = "$WLOC_AP_WANTED_IFNAME" ] &&
		wloc_ap_valid_ifname "$ifname" &&
		printf '%s\n' "$section"
}

wloc_ap_find_sections_by_ifname() {
	WLOC_AP_WANTED_IFNAME="$1"
	wloc_ap_valid_ifname "$WLOC_AP_WANTED_IFNAME" || return 0
	config_load wireless || return 1
	config_foreach wloc_ap_collect_section_by_ifname wifi-iface
}

wloc_ap_find_section_by_ifname() {
	local ifname="$1" section count candidate
	count=0
	section=''
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		count=$((count + 1))
		section="$candidate"
	done <<EOF
$(wloc_ap_find_sections_by_ifname "$ifname")
EOF
	case "$count" in
		0)
			echo "interface \"$ifname\" was not found in wireless configuration" >&2
			return 1
			;;
		1) printf '%s\n' "$section"; return 0;;
		*)
			echo "interface \"$ifname\" matches multiple wireless sections" >&2
			return 2
			;;
	esac
}

wloc_ap_get_hostapd_status() {
	local ifname="$1"
	wloc_ap_valid_ifname "$ifname" || return 1
	ubus -S -t 3 call "hostapd.$ifname" get_status '{}' 2>/dev/null
}
