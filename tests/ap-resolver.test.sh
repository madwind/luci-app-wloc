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
	"$1" wifi0
	"$1" wifi1
	"$1" wifi2
}
config_get() {
	local destination="$1" section="$2" option="$3" value="${4:-}"
	case "$section:$option" in
		wifi0:mode) value=ap;; wifi0:ssid) value="$ssid0";; wifi0:network) value=lan;;
		wifi1:mode) value=ap;; wifi1:ssid) value="$ssid1";; wifi1:network) value=lan;;
		wifi2:mode) value=ap;; wifi2:ssid) value=Home;; wifi2:network) value=lan;;
	esac
	eval "$destination=\$value"
}
EOF

export WLOC_LIB_FUNCTIONS="$lib_functions"
export WLOC_AP_LIB_LOADED=0
ssid0='SSID-A'
ssid1='Home'
uci() {
	[ "${1:-}" = -q ] && shift
	[ "${1:-}" = get ] || return 1
	case "${2:-}" in
		network.lan.device) printf '%s\n' br-lan;;
		*) return 1;;
	esac
}
ubus() { return 1; }

eval "$(sed '/^wloc_ap_get_runtime_ifname()/,$d' "$AP_LIB")"

[ "$(wloc_ap_find_section_by_ssid 'SSID-A')" = wifi0 ]
if wloc_ap_find_section_by_ssid 'ssid-a' >/dev/null 2>"$fixture_root/error"; then
	echo 'case-sensitive SSID lookup unexpectedly succeeded' >&2
	exit 1
fi
grep -F 'SSID "ssid-a" was not found in wireless configuration' "$fixture_root/error" >/dev/null

if wloc_ap_find_section_by_ssid Home >/dev/null 2>"$fixture_root/error"; then
	echo 'duplicate SSID lookup unexpectedly succeeded' >&2
	exit 1
fi
[ "$(cat "$fixture_root/error")" = 'SSID "Home" matches multiple wireless interfaces' ]

[ "$(wloc_ap_get_network wifi0)" = lan ]
[ "$(wloc_ap_get_network_device lan)" = br-lan ]

echo 'AP resolver tests: PASS'
