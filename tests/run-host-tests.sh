#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="$ROOT/root"
HTDOCS="$ROOT/htdocs"

RULES="$ROOTFS/usr/libexec/wloc/rules.sh"
SCHEDULE="$ROOTFS/usr/libexec/wloc/wifi-schedule.sh"
AP_TEST="$ROOT/tests/ap-discovery.test.js"
AP_RESOLVER_TEST="$ROOT/tests/ap-resolver.test.sh"

fail() {
	echo "host tests: FAIL: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 \
		|| fail "required command not found: $1"
}

for command in sh find python3 node sed awk sort; do
	need "$command"
done

[ -d "$ROOTFS" ] || fail "root directory not found"
[ -d "$HTDOCS" ] || fail "htdocs directory not found"
[ -f "$RULES" ] || fail "rules.sh not found"
[ -f "$AP_TEST" ] || fail "AP discovery test not found"
[ -f "$AP_RESOLVER_TEST" ] || fail "AP resolver test not found"


echo '==> Shell syntax'

while IFS= read -r -d '' script; do
	sh -n "$script" || fail "shell syntax error: $script"
done < <(
	find "$ROOTFS" -type f \
		\( \
			-name '*.sh' \
			-o -path '*/etc/init.d/*' \
			-o -path '*/etc/uci-defaults/*' \
			-o -path '*/usr/libexec/rpcd/*' \
		\) \
		-print0
)


echo '==> JSON syntax'

while IFS= read -r -d '' json; do
	python3 -m json.tool "$json" >/dev/null \
		|| fail "invalid JSON: $json"
done < <(
	find "$ROOTFS" -type f -name '*.json' -print0
)


echo '==> JavaScript syntax'

while IFS= read -r -d '' js; do
	node --check "$js" >/dev/null \
		|| fail "JavaScript syntax error: $js"
done < <(
	find "$HTDOCS" -type f -name '*.js' -print0
)


echo '==> JavaScript behavior'

node "$AP_TEST"


echo '==> AP resolver behavior'

sh "$AP_RESOLVER_TEST"


echo '==> WLOC shell behavior'

# Load function definitions from rules.sh without executing its command dispatcher.
eval "$(sed '/^case /,$d' "$RULES")"


echo '  -> port validation'

valid_port 1 \
	|| fail 'valid_port rejected port 1'

valid_port 61520 \
	|| fail 'valid_port rejected port 61520'

valid_port 65535 \
	|| fail 'valid_port rejected port 65535'

if valid_port 0; then
	fail 'valid_port accepted port 0'
fi

if valid_port 65536; then
	fail 'valid_port accepted port 65536'
fi

if valid_port abc; then
	fail 'valid_port accepted a non-numeric port'
fi


echo '  -> interface-name validation'

valid_ifname 'br-wloc-us' \
	|| fail 'valid_ifname rejected a valid bridge'

valid_ifname 'phy0-ap0' \
	|| fail 'valid_ifname rejected a valid bridge member'

if valid_ifname 'br wloc'; then
	fail 'valid_ifname accepted whitespace'
fi

if valid_ifname 'br/wloc'; then
	fail 'valid_ifname accepted a slash'
fi

if valid_ifname 'br-1234567890123'; then
	fail 'valid_ifname accepted an overlong interface name'
fi


echo '  -> nftables table health'

empty_host_set_fixture='table inet wloc {
	set target_ingress_interfaces {
		type ifname
		flags timeout
	}

	set apple_wloc_v4 {
		type ipv4_addr
		flags timeout
	}

	chain redirect_prerouting {
		type nat hook prerouting priority mangle - 2; policy accept;
		iifname @target_ingress_interfaces ip daddr @apple_wloc_v4 tcp dport 443 counter redirect to :61520 comment "wloc owned ingress redirect"
	}
}'

printf '%s\n' "$empty_host_set_fixture" \
	| table_healthy 61520 \
	|| fail 'table_healthy rejected a valid table with an empty host set'

if printf '%s\n' "$empty_host_set_fixture" \
	| table_healthy 61521; then
	fail 'table_healthy accepted the wrong redirect port'
fi

if printf '%s\n' "$empty_host_set_fixture" \
	| sed 's/ counter / /' \
	| table_healthy 61520; then
	fail 'table_healthy accepted a redirect rule without counter'
fi

if printf '%s\n' "$empty_host_set_fixture" \
	| sed '/flags timeout/d' \
	| table_healthy 61520; then
	fail 'table_healthy accepted sets without timeout'
fi

if printf '%s\n' "$empty_host_set_fixture" \
	| sed '/wloc owned ingress redirect/d' \
	| table_healthy 61520; then
	fail 'table_healthy accepted a missing redirect rule'
fi


echo '  -> SSID-resolved ingress synchronization'

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/br-lan/brif"
: >"$fixture_root/br-lan/brif/phy0-ap0"
: >"$fixture_root/br-lan/brif/phy1-ap0"
export WLOC_SYS_CLASS_NET="$fixture_root"

nft() {
	if [ "${1:-}" = '-f' ] && [ "${2:-}" = '-' ]; then
		cat
		return 0
	fi
	if [ "${1:-}" = list ] && [ "${2:-}" = set ] && [ "${5:-}" = target_ingress_interfaces ]; then
		return 0
	fi
	return 1
}

resolver_lib="$fixture_root/resolver-lib.sh"
printf '%s\n' \
	'config_load() { resolver_config="$1"; }' \
	'config_foreach() {' \
	'  if [ "$resolver_config" = wloc ]; then "$1" location_us; "$1" location_jp;' \
	'  elif [ "$resolver_config" = wireless ]; then "$1" wifi_us; "$1" wifi_jp;' \
	'  fi' \
	'}' \
	'config_get() {' \
	'  local destination="$1" section="$2" option="$3" value="${4:-}"' \
	'  case "$section:$option" in' \
	'    location_us:enabled|location_jp:enabled) value=1;;' \
	'    location_us:ssid) value=SSID-US;; location_jp:ssid) value=SSID-JP;;' \
	'    wifi_us:mode|wifi_jp:mode) value=ap;;' \
	'    wifi_us:ssid) value=SSID-US;; wifi_jp:ssid) value=SSID-JP;;' \
	'    wifi_us:network|wifi_jp:network) value=lan;;' \
	'  esac' \
	'  eval "$destination=\$value"' \
	'}' \
	'config_get_bool() { config_get "$@"; }' \
	>"$resolver_lib"
export WLOC_LIB_FUNCTIONS="$resolver_lib"
export WLOC_AP_LIB_PATH="$ROOTFS/usr/libexec/wloc/ap-lib.sh"
AP_LIB="$WLOC_AP_LIB_PATH"
uci() {
	[ "${1:-}" = '-q' ] && shift
	[ "${1:-}" = get ] || return 1
	case "${2:-}" in
		network.lan.device) printf '%s\n' br-lan;;
		*) return 1;;
	esac
}
load_ap_lib

expected_ingress_batch='flush set inet wloc target_ingress_interfaces
add element inet wloc target_ingress_interfaces { "br-lan" timeout 30s }
add element inet wloc target_ingress_interfaces { "phy0-ap0" timeout 30s }
add element inet wloc target_ingress_interfaces { "phy1-ap0" timeout 30s }'
[ "$(sync_ingress_interfaces)" = "$expected_ingress_batch" ] \
	|| fail 'SSID-resolved ingress synchronization generated an unexpected batch'

[ "$(sync_ingress_interfaces)" = "$expected_ingress_batch" ] \
	|| fail 'reconcile was not idempotent or did not deduplicate shared bridge interfaces'


if grep -Eq 'rule\.bridge|duplicate bridge' \
	"$ROOT/src/wloc-rs/src/config.rs" "$ROOT/src/wloc-rs/src/main.rs" "$ROOT/src/wloc-rs/src/proxy.rs" "$RULES"; then
	fail 'bridge identity or duplicate-bridge validation remains in core WLOC code'
fi

if grep -Eq 'find_wireless_by_bssid|resolve_old_wireless_section|network_bridge' \
	"$ROOTFS/etc/uci-defaults/luci-app-wloc"; then
	fail 'SSID migration still contains a BSSID/bridge fallback'
fi

grep -F 'wloc_ap_find_section_by_ssid' "$RULES" >/dev/null \
	|| fail 'rules.sh does not resolve ingress from configured SSIDs'

grep -F 'json_add_boolean unique' "$ROOTFS/usr/libexec/rpcd/luci.wloc" >/dev/null \
	|| fail 'RPC AP discovery does not expose SSID uniqueness'


echo '  -> SSID-based schedule synchronization'

if grep -Eq 'runtime_bssid_for_ifname|wireless_ifname|network.*bssid' "$SCHEDULE"; then
	fail 'wifi schedule still contains a BSSID or runtime-interface fallback'
fi

schedule_lib="$fixture_root/schedule-lib.sh"
printf '%s\n' \
	'config_load() { schedule_config="$1"; }' \
	'config_foreach() {' \
	'  if [ "$schedule_config" = wloc ]; then "$1" wifi_us;' \
	'  elif [ "$schedule_config" = wireless ] && [ "${fake_wireless_exists:-0}" -eq 1 ]; then "$1" wifi_ap; fi' \
	'}' \
	'config_get() {' \
	'  local destination="$1" section="$2" option="$3" value' \
	'  local default="${4:-}"' \
	'  value="$default"' \
	'  case "$option" in' \
	'    enabled) value=1;;' \
	'    schedule_enabled) value="$schedule_enabled_value";;' \
	'    schedule_start) value=00:00;;' \
	'    schedule_end) value=00:00;;' \
	'    ssid) value=WLOC-US;;' \
	'    mode) value=ap;;' \
	'    network) value=lan;;' \
	'  esac' \
	'  eval "$destination=\$value"' \
	'}' \
	'config_get_bool() { config_get "$@"; }' \
	>"$schedule_lib"
export WLOC_LIB_FUNCTIONS="$schedule_lib"
export WLOC_AP_LIB_PATH="$ROOTFS/usr/libexec/wloc/ap-lib.sh"
export WLOC_SCHEDULE_STATE_DIR="$fixture_root"
eval "$(sed '/^case /,$d' "$SCHEDULE")"

fake_wireless_exists=1
fake_disabled=0
	schedule_enabled_value=1
reload_count=0
uci() {
	[ "${1:-}" = '-q' ] && shift
	case "${1:-}" in
		get)
			case "${2:-}" in
				wireless.wifi_ap)
					[ "$fake_wireless_exists" -eq 1 ] || return 1
					;;
				wireless.wifi_ap.disabled)
					[ "$fake_wireless_exists" -eq 1 ] || return 1
					printf '%s\n' "$fake_disabled"
					;;
				*) return 1;;
			esac
			;;
		set)
			fake_disabled="${2#*=}"
			;;
		delete)
			fake_disabled=0
			;;
		*) return 1;;
	esac
}
wifi() { reload_count=$((reload_count + 1)); }
logger() { :; }

reconcile
[ "$fake_disabled" = 1 ] || fail 'schedule did not disable the SSID-resolved wireless section'
[ "$(cat "$fixture_root/wifi-schedule.state")" = 'wifi_ap|0' ] \
	|| fail 'schedule did not record the original disabled value'
[ "$reload_count" -eq 1 ] || fail 'schedule did not reload WiFi after disabling'

	schedule_enabled_value=0
reconcile
[ "$fake_disabled" = 0 ] || fail 'schedule did not restore the original disabled value'
[ ! -e "$fixture_root/wifi-schedule.state" ] || fail 'schedule state was not cleared after restore'
[ "$reload_count" -eq 2 ] || fail 'schedule did not reload WiFi after restore'

	schedule_enabled_value=1
fake_wireless_exists=0
reconcile
[ "$fake_disabled" = 0 ] || fail 'schedule changed state for a missing SSID'
[ "$reload_count" -eq 2 ] || fail 'schedule reloaded WiFi for a missing SSID'


echo 'host tests: PASS'
