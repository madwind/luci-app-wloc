#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="$ROOT/root"
HTDOCS="$ROOT/htdocs"

RULES="$ROOTFS/usr/libexec/wloc/rules.sh"
RPC="$ROOTFS/usr/libexec/rpcd/luci.wloc"
FIREWALL_HELPER="$ROOTFS/usr/libexec/wloc/firewall.sh"
SCHEDULE="$ROOTFS/usr/libexec/wloc/wifi-schedule.sh"
INIT="$ROOTFS/etc/init.d/wloc"
AP_TEST="$ROOT/tests/ap-discovery.test.js"
AP_RESOLVER_TEST="$ROOT/tests/ap-resolver.test.sh"
LIFECYCLE_TEST="$ROOT/tests/firewall-lifecycle.test.sh"
RPC_FIREWALL_TEST="$ROOT/tests/rpc-firewall-lifecycle.test.sh"

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
[ -f "$FIREWALL_HELPER" ] || fail "firewall.sh not found"
[ -f "$AP_TEST" ] || fail "AP discovery test not found"
[ -f "$AP_RESOLVER_TEST" ] || fail "AP resolver test not found"
[ -f "$LIFECYCLE_TEST" ] || fail "WLOC lifecycle test not found"
[ -f "$RPC_FIREWALL_TEST" ] || fail "WLOC RPC firewall test not found"


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


echo '==> Service startup behavior'

grep -Fq 'rm -f /tmp/luci-indexcache.*' "$ROOT/Makefile" \
	|| fail 'package postinst does not clear the LuCI index cache'
grep -Fq 'rm -rf /tmp/luci-modulecache/' "$ROOT/Makefile" \
	|| fail 'package postinst does not clear the LuCI module cache'
grep -Fq '/etc/init.d/rpcd reload' "$ROOT/Makefile" \
	|| fail 'package postinst does not reload rpcd'
grep -Fq '/etc/init.d/wloc start' "$ROOT/Makefile" \
	|| fail 'package postinst does not start wloc without an unnecessary restart'
if grep -Fq '/etc/init.d/rpcd restart' "$ROOT/Makefile"; then
	fail 'package postinst still restarts rpcd'
fi
grep -Fq 'group: checks-${{ github.workflow }}-${{ github.ref }}' "$ROOT/.github/workflows/ci.yml" \
	|| fail 'standalone and reusable checks do not have isolated concurrency keys'

grep -Fq 'FIREWALL_HELPER=/usr/libexec/wloc/firewall.sh' "$INIT" \
	|| fail 'init script does not configure the shared firewall helper'
grep -Fq '"$FIREWALL_HELPER" apply "$FIREWALL"' "$INIT" \
	|| fail 'service start does not invoke the shared firewall helper'
if grep -Fq 'ubus -S call luci.wloc firewall_apply' "$INIT"; then
	fail 'service start still depends on the luci.wloc RPC'
fi
grep -Fq 'WLOC_FIREWALL_HELPER_SOURCE=1' "$RPC" \
	|| fail 'rpcd does not source the shared firewall helper'
grep -Fq 'firewall_runtime_reconcile' "$FIREWALL_HELPER" \
	|| fail 'firewall helper does not support immediate runtime reconciliation'
grep -Fq 'firewall_runtime_cleanup' "$FIREWALL_HELPER" \
	|| fail 'firewall helper does not fail open while wlocd is stopped'
grep -Fq 'firewall_wloc_ready' "$FIREWALL_HELPER" \
	|| fail 'firewall helper does not gate dynamic sets on daemon readiness'
grep -Fq 'firewall_active' "$RPC" \
	|| fail 'status RPC does not expose live firewall activity'

grep -Fq 'listener_ready' "$INIT" \
	|| fail 'service start does not defer dynamic-set population until listener readiness'
grep -Fq 'firewall.applied.nft' "$INIT" \
	|| fail 'service start does not clear the volatile applied firewall snapshot'
grep -Fq 'firewall.candidate.nft' "$INIT" \
	|| fail 'service start does not clear the volatile candidate firewall snapshot'
grep -Fq 'procd_open_instance daemon' "$INIT" \
	|| fail 'daemon procd instance is not explicitly named'
grep -Fq 'procd_open_instance schedule' "$INIT" \
	|| fail 'schedule procd instance is not explicitly named'
grep -Fq 'procd_set_param respawn' "$INIT" \
	|| fail 'procd respawn is not configured'
grep -Fq 'procd_set_param stdout 1' "$INIT" \
	|| fail 'daemon stdout is not connected to logd'
grep -Fq 'procd_set_param stderr 1' "$INIT" \
	|| fail 'daemon stderr is not connected to logd'
grep -Fq 'procd_add_reload_trigger wloc' "$INIT" \
	|| fail 'service reload trigger is missing'
if grep -Fq 'ubus -S call luci.wloc' "$INIT"; then
	fail 'service start still calls luci.wloc through ubus'
fi
grep -Fq 'procd_set_param command /usr/sbin/wlocd --listen-port "$listen_port"' "$INIT" \
	|| fail 'service start still passes a daemon GID'
if grep -Eq 'gid|GID|--gid' "$INIT"; then
	fail 'init script still contains daemon GID handling'
fi
if grep -Eq 'pidfile|daemonize|(^|[[:space:]])&([[:space:]]|$)' "$INIT"; then
	fail 'init script contains self-managed daemonization or background execution'
fi
grep -Fq 'service_daemon_running' "$RPC" \
	|| fail 'status RPC does not query the procd service state'
grep -Fq 'ubus call service list' "$RPC" \
	|| fail 'status RPC does not query ubus service list'
if grep -Fq 'sleep 1' "$RPC"; then
	fail 'status RPC still waits with a fixed one-second sleep'
fi
grep -Fq 'state restarting' "$RPC" \
	|| fail 'restart RPC does not return an immediate accepted state'

echo '==> WLOC recovery behavior'

grep -Fq 'DNS_RETRY_SECONDS=10' "$RULES" \
	|| fail 'DNS failures are still throttled for longer than one reconcile interval'
grep -Fq 'INGRESS_INTERFACE_TIMEOUT=120s' "$RULES" \
	|| fail 'ingress leases do not tolerate a long reconcile gap'
grep -Fq 'resolve_hosts ||' "$RULES" \
	|| fail 'reconcile does not propagate host-set failures'
grep -Fq 'sync_ingress_interfaces ||' "$RULES" \
	|| fail 'reconcile does not propagate ingress-set failures'
if grep -Eq 'ORDER_STATE|ORDER_CHECK_STAMP|PRIORITY_STATE|PRIORITY_DETAILS|analyze_prerouting_proxies|write_priority_details|read_wloc_priority|read_wloc_chain|order_check_due|mark_order_checked|check_prerouting_order' "$RULES"; then
	fail 'obsolete prerouting priority/order state remains in rules.sh'
fi


echo '==> Fixed Apple WLOC domains'

grep -Eq '^[[:space:]]+option schema_version '\''7'\''$' "$ROOTFS/etc/config/wloc" \
	|| fail 'UCI configuration schema is not version 7'
if grep -Eq '^[[:space:]]*list domain([[:space:]]|$)' "$ROOTFS/etc/config/wloc"; then
	fail 'UCI configuration still stores configurable WLOC domains'
fi
grep -Fq "HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'" "$RULES" \
	|| fail 'rules.sh does not use the two fixed Apple endpoints'
grep -Fq 'DEFAULT_DOMAINS' "$ROOT/src/wloc-rs/src/lib.rs" \
	|| fail 'Rust service does not define the fixed Apple endpoints'
grep -Fq "uci -q delete wloc.main.domain" "$ROOTFS/etc/uci-defaults/luci-app-wloc" \
	|| fail 'migration does not remove legacy configurable domains'
if grep -REq -- '--domain|config_list_foreach main domain' \
	"$INIT" "$RULES" "$ROOT/src/wloc-rs/src"; then
	fail 'runtime code still accepts configurable WLOC domains'
fi


echo '==> WLOC lifecycle behavior'

sh "$LIFECYCLE_TEST"
sh "$RPC_FIREWALL_TEST"

echo '==> nftables editor behavior'

if grep -Fq 'Only top-level table declarations are allowed.' "$RPC"; then
	fail 'nftables editor still rejects valid top-level commands'
fi
grep -F 'nft --check --file' "$FIREWALL_HELPER" >/dev/null \
	|| fail 'nftables editor no longer performs a syntax-only check'
grep -F 'FIREWALL_CANDIDATE=' "$FIREWALL_HELPER" >/dev/null \
	|| fail 'firewall helper does not define a volatile candidate snapshot'
grep -F 'firewall_copy_atomic' "$FIREWALL_HELPER" >/dev/null \
	|| fail 'firewall helper does not provide atomic snapshot replacement'
grep -F 'firewall_request_config' "$RPC" >/dev/null \
	|| fail 'apply and validate RPCs do not receive editor content'
grep -F 'firewall_copy_atomic "$FIREWALL_RUNTIME" "$FIREWALL"' "$RPC" >/dev/null \
	|| fail 'save RPC does not copy the applied snapshot to persistent storage'
if grep -Fq "callSave(editor.value)" "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js"; then
	fail 'firewall save still accepts un-applied editor contents'
fi
grep -F 'callApply(editor.value)' "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" >/dev/null \
	|| fail 'firewall apply does not receive editor contents'
if grep -Fq 'Save & apply' "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js"; then
	fail 'firewall editor still exposes a combined Save & apply action'
fi
grep -F "'    '.repeat(indent)" "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" >/dev/null \
	|| fail 'nftables editor formatter does not use four-space indentation'
if grep -Fq "'\\t'.repeat(indent)" "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js"; then
	fail 'nftables editor formatter still emits tabs'
fi


echo '==> AP resolver behavior'

sh "$AP_RESOLVER_TEST"


echo '==> WLOC shell behavior'

# Load function definitions from rules.sh without executing its command dispatcher.
WLOC_RULES_SOURCE=1
. "$RULES"


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


echo '  -> fixed interface-name validation'

valid_ifname 'phy0-ap0' \
	|| fail 'valid_ifname rejected a valid fixed AP interface'

if valid_ifname 'phy 0-ap0'; then
	fail 'valid_ifname accepted whitespace'
fi

if valid_ifname 'phy0/ap0'; then
	fail 'valid_ifname accepted a slash'
fi

if valid_ifname 'phy-1234567890123'; then
	fail 'valid_ifname accepted an overlong interface name'
fi


echo '  -> unrestricted nftables rules'

if grep -Eq 'table_healthy|bridge_table_healthy|ensure_table_healthy' "$RULES"; then
	fail 'rules.sh still enforces a fixed nftables table layout'
fi

grep -F 'refresh_hosts()' "$RULES" >/dev/null \
	|| fail 'rules.sh no longer maintains the optional host set'
grep -F 'active_ingress_set' "$RULES" >/dev/null \
	|| fail 'rules.sh no longer maintains the optional ingress set'


echo '  -> fixed-interface ingress synchronization'

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/br-lan/brif"
: >"$fixture_root/br-lan/brif/lan2"
: >"$fixture_root/br-lan/brif/lan3"
: >"$fixture_root/br-lan/brif/lan4"
: >"$fixture_root/br-lan/brif/phy0-ap0"
: >"$fixture_root/br-lan/brif/phy1-ap0"
: >"$fixture_root/br-lan/brif/phy0-ap1"
export WLOC_SYS_CLASS_NET="$fixture_root"

nft() {
	if [ "${1:-}" = '-f' ] && [ "${2:-}" = '-' ]; then
		cat
		return 0
	fi
	if [ "${1:-}" = list ] && [ "${2:-}" = set ] && [ "${5:-}" = target_ingress_interfaces ]; then
		printf '%s\n' 'type ifname' 'flags timeout'
		return 0
	fi
	return 1
}

resolver_lib="$fixture_root/resolver-lib.sh"
printf '%s\n' \
	'config_load() { resolver_config="$1"; }' \
	'config_foreach() {' \
	'  if [ "$resolver_config" = wloc ]; then "$1" location_us; "$1" location_jp;' \
	'  elif [ "$resolver_config" = wireless ]; then "$1" wifi_us; "$1" wifi_jp; "$1" wifi_unfixed;' \
	'  fi' \
	'}' \
	'config_get() {' \
	'  local destination="$1" section="$2" option="$3" value="${4:-}"' \
	'  case "$section:$option" in' \
	'    location_us:enabled|location_jp:enabled) value=1;;' \
	'    location_us:iface) value=phy0-ap0;; location_jp:iface) value=phy1-ap0;;' \
	'    wifi_us:mode|wifi_jp:mode) value=ap;;' \
	'    wifi_us:ifname) value=phy0-ap0;; wifi_jp:ifname) value=phy1-ap0;;' \
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
	return 1
}
load_ap_lib

expected_ingress_batch='flush set bridge wloc target_ingress_interfaces
add element bridge wloc target_ingress_interfaces { "phy0-ap0" timeout 120s }
add element bridge wloc target_ingress_interfaces { "phy1-ap0" timeout 120s }'
[ "$(sync_ingress_interfaces)" = "$expected_ingress_batch" ] \
	|| fail 'fixed-interface ingress synchronization generated an unexpected batch'

[ "$(sync_ingress_interfaces)" = "$expected_ingress_batch" ] \
	|| fail 'reconcile was not idempotent or did not deduplicate configured AP interfaces'

nft() { return 1; }
[ -z "$(sync_ingress_interfaces)" ] \
	|| fail 'missing optional ingress set prevented reconciliation'


if grep -Eq 'rule\.bridge|duplicate bridge' \
	"$ROOT/src/wloc-rs/src/config.rs" "$ROOT/src/wloc-rs/src/main.rs" "$ROOT/src/wloc-rs/src/proxy.rs" "$RULES"; then
	fail 'bridge identity or duplicate-bridge validation remains in core WLOC code'
fi

if grep -Eq 'resolve_ingress_interfaces|/brif/' "$RULES"; then
	fail 'ingress synchronization still scans bridge members'
fi

if grep -Eq 'find_wireless_by_bssid|resolve_old_wireless_section|network_bridge' \
	"$ROOTFS/etc/uci-defaults/luci-app-wloc"; then
	fail 'interface migration still contains a BSSID/bridge fallback'
fi

grep -F 'wloc_ap_find_section_by_ifname' "$RULES" >/dev/null \
	|| fail 'rules.sh does not resolve ingress from configured interfaces'

grep -F 'wloc_ap_valid_ifname' "$ROOTFS/usr/libexec/rpcd/luci.wloc" >/dev/null \
	|| fail 'RPC AP discovery does not filter missing fixed ifnames'

grep -F 'json_add_string iface' "$ROOTFS/usr/libexec/rpcd/luci.wloc" >/dev/null \
	|| fail 'RPC AP discovery does not expose fixed interfaces'

if grep -Eq 'json_add_(string|boolean) (network|device|radio|bssid|unique|ambiguous)' \
	"$ROOTFS/usr/libexec/rpcd/luci.wloc"; then
	fail 'RPC AP discovery still exposes removed AP metadata'
fi


echo '  -> fixed-interface schedule synchronization'

if grep -Eq 'ssid|bssid|wireless_ifname|network' "$SCHEDULE"; then
	fail 'wifi schedule still contains SSID or obsolete AP metadata'
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
	'    iface) value=phy0-ap0;;' \
	'    mode) value=ap;;' \
	'    ifname) value=phy0-ap0;;' \
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
[ "$fake_disabled" = 1 ] || fail 'schedule did not disable the fixed-interface wireless section'
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
[ "$fake_disabled" = 0 ] || fail 'schedule changed state for a missing interface'
[ "$reload_count" -eq 2 ] || fail 'schedule reloaded WiFi for a missing interface'


echo 'host tests: PASS'
