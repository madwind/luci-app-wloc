#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AP_LIB="$ROOT/root/usr/libexec/wloc/ap-lib.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

lib_functions="$fixture_root/lib-functions.sh"
cat >"$lib_functions" <<'EOF'
config_load() { loaded_config="$1"; }
config_foreach() {
	[ "$loaded_config" = wireless ] || return 0
	"$1" wifi0 || :
	"$1" wifi1 || :
	"$1" wifi2 || :
}
config_get() {
	local destination="$1" section="$2" option="$3" value="${4:-}"
	case "$section:$option" in
		wifi0:mode|wifi1:mode|wifi2:mode) value=ap;;
		wifi0:ifname) value=phy0-ap0;;
		wifi1:ifname) value=phy0-ap1;;
		wifi2:ifname) value=phy1-ap0;;
	esac
	eval "$destination=\$value"
}
EOF

export WLOC_LIB_FUNCTIONS="$lib_functions"
export WLOC_AP_LIB_LOADED=0
uci() {
	[ "${1:-}" = -q ] && shift
	return 1
}
ubus() { return 1; }

eval "$(sed '/^wloc_ap_get_hostapd_status()/,$d' "$AP_LIB")"

[ "$(wloc_ap_find_section_by_ifname 'phy0-ap0')" = wifi0 ]
if wloc_ap_find_section_by_ifname 'PHY0-AP0' >/dev/null 2>"$fixture_root/error"; then
	echo 'case-sensitive interface lookup unexpectedly succeeded' >&2
	exit 1
fi
grep -F 'interface "PHY0-AP0" was not found in wireless configuration' "$fixture_root/error" >/dev/null

if wloc_ap_find_section_by_ifname '' >/dev/null 2>"$fixture_root/error"; then
	echo 'empty interface lookup unexpectedly succeeded' >&2
	exit 1
fi

echo 'AP resolver tests: PASS'
