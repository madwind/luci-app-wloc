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
FIREWALL_CONCURRENCY_TEST="$ROOT/tests/firewall-concurrency.test.sh"
FIREWALL_SAFETY_TEST="$ROOT/tests/firewall-command-safety.test.sh"
RPC_FIREWALL_TEST="$ROOT/tests/rpc-firewall-lifecycle.test.sh"
CLEANUP_FAILURE_TEST="$ROOT/tests/cleanup-failure.test.sh"
RUNTIME_STATUS_TEST="$ROOT/tests/runtime-status.test.sh"
FIREWALL_UI_TEST="$ROOT/tests/firewall-ui.test.js"
FIREWALL_VIEW="$HTDOCS/luci-static/resources/view/wloc/firewall.js"
MAIN_VIEW="$HTDOCS/luci-static/resources/view/wloc/main.js"
RUNTIME_INTEGRATION_TEST="$ROOT/tests/runtime-integration.sh"
BUILD_SCRIPT="$ROOT/scripts/build-openwrt-25.12.5.sh"

fail() {
    echo "host tests: FAIL: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

for command in sh find node sed awk; do
    need "$command"
done

[ -d "$ROOTFS" ] || fail "root directory not found"
[ -d "$HTDOCS" ] || fail "htdocs directory not found"
for required in "$RULES" "$RPC" "$FIREWALL_HELPER" "$AP_TEST" \
    "$AP_RESOLVER_TEST" "$LIFECYCLE_TEST" "$FIREWALL_CONCURRENCY_TEST" \
    "$FIREWALL_SAFETY_TEST" "$RPC_FIREWALL_TEST" "$CLEANUP_FAILURE_TEST" \
    "$RUNTIME_STATUS_TEST" "$FIREWALL_UI_TEST" "$FIREWALL_VIEW" "$MAIN_VIEW" \
    "$RUNTIME_INTEGRATION_TEST" "$BUILD_SCRIPT"; do
    [ -f "$required" ] || fail "required test or source file is missing: $required"
done

echo '==> Shell, JSON, and JavaScript syntax'
while IFS= read -r -d '' script; do
    sh -n "$script" || fail "shell syntax error: $script"
done < <(
    find "$ROOTFS" -type f \
        \( -name '*.sh' -o -path '*/etc/init.d/*' -o -path '*/etc/uci-defaults/*' \
        -o -path '*/usr/libexec/rpcd/*' \) -print0
)
sh -n "$RUNTIME_INTEGRATION_TEST" || fail "shell syntax error: $RUNTIME_INTEGRATION_TEST"
while IFS= read -r -d '' json; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$json" \
        || fail "invalid JSON: $json"
done < <(find "$ROOTFS" -type f -name '*.json' -print0)
while IFS= read -r -d '' js; do
    node --check "$js" >/dev/null || fail "JavaScript syntax error: $js"
done < <(find "$HTDOCS" -type f -name '*.js' -print0)

echo '==> JavaScript behavior'
node "$AP_TEST"
node "$FIREWALL_UI_TEST"

echo '==> Fixed firewall ownership contract'
grep -Fq 'FIREWALL_BRIDGE_FAMILY=bridge' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not define the bridge WLOC table'
grep -Fq 'FIREWALL_INET_FAMILY=inet' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not define the inet WLOC table'
grep -Fq 'FIREWALL_TABLE=wloc' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not define the fixed WLOC table name'
grep -Fq 'nft list table' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not query live WLOC tables'
grep -Fq 'nft delete table' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not clean up fixed WLOC tables'
grep -Fq 'nft --check --file' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not delegate syntax validation to nft'
grep -Fq 'unsupported_firewall_command' "$FIREWALL_HELPER" "$RPC" \
    || fail 'firewall ownership error is not exposed by the backend'
grep -Fq 'Only table bridge wloc and table inet wloc definitions are supported.' "$RPC" \
    || fail 'backend does not explain the fixed ownership boundary'
if grep -Eq 'firewall_tables|firewall_validate_declarative|firewall_snapshot|declarative_set_targets|host_set_targets|ingress_set_targets|host_set_compatible|ingress_set_compatible|CUSTOM_FIREWALL|PERSISTENT_FIREWALL' "$FIREWALL_HELPER" "$RULES"; then
    fail 'generic nftables discovery or schema parsing remains'
fi
if grep -Eq 'active_source|table_healthy|custom table|arbitrary table|multiple.*target' "$FIREWALL_HELPER" "$RULES" "$RPC"; then
    fail 'generic table diagnostics remain'
fi

echo '==> Service integration'
if grep -Eq '^define Package/luci-app-wloc/postinst$|/etc/init.d/wloc (enable|start|disable)|/etc/init.d/wloc stop' "$ROOT/Makefile"; then
    fail 'package hooks duplicate standard service lifecycle'
fi
grep -Fq 'firewall.sh remove-runtime' "$ROOT/Makefile" \
    || fail 'package prerm does not clean up WLOC firewall state'
grep -Fq 'WLOC_FIREWALL_HELPER_SOURCE=1' "$RPC" \
    || fail 'rpcd does not source the shared firewall helper'
grep -Fq '"$FIREWALL_HELPER" apply "$FIREWALL"' "$INIT" \
    || fail 'service start does not invoke the shared firewall helper'
grep -Fq 'service_daemon_running' "$RPC" \
    || fail 'status RPC does not query procd service state'
grep -Fq 'ubus call service list' "$RPC" \
    || fail 'status RPC does not query ubus service list'
grep -Fq 'firewall_active' "$RPC" \
    || fail 'status RPC does not expose live firewall activity'
grep -Fq 'runtime_log_revision' "$RPC" \
    || fail 'status RPC does not expose runtime log revision'
grep -Fq 'lastLogRevision' "$MAIN_VIEW" \
    || fail 'LuCI does not retain runtime log revision'
if grep -Eq 'firewall_process_start|firewall_lock_(save_traps|restore_trap|abort|install_traps|owner_alive|remove_stale)|FIREWALL_LOCK_OWNER|trap -p|/owner' "$FIREWALL_HELPER"; then
    fail 'firewall helper contains a custom owner/trap lock'
fi

echo '==> Recovery and fixed WLOC inputs'
grep -Fq 'DNS_RETRY_SECONDS=10' "$RULES" || fail 'DNS retry interval changed'
grep -Fq 'INGRESS_INTERFACE_TIMEOUT=120s' "$RULES" || fail 'ingress lease interval changed'
grep -Fq "HOST_FAMILY=inet" "$RULES" || fail 'host set family is not fixed to inet'
grep -Fq "HOST_TABLE=wloc" "$RULES" || fail 'host set table is not fixed to wloc'
grep -Fq "INGRESS_FAMILY=bridge" "$RULES" || fail 'ingress set family is not fixed to bridge'
grep -Fq "INGRESS_TABLE=wloc" "$RULES" || fail 'ingress set table is not fixed to wloc'
grep -Fq "HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'" "$RULES" \
    || fail 'rules.sh does not use the fixed Apple endpoints'
grep -Fq 'wloc_ap_find_section_by_ifname' "$RULES" \
    || fail 'rules.sh does not resolve fixed AP interfaces'
if grep -Eq 'resolve_ingress_interfaces|/brif/|ORDER_STATE|PRIORITY_STATE|analyze_prerouting_proxies' "$RULES"; then
    fail 'rules.sh still contains removed generic or bridge-scanning logic'
fi
if grep -Eq 'ssid|bssid|wireless_ifname|network' "$SCHEDULE"; then
    fail 'wifi schedule contains obsolete AP metadata'
fi

echo '==> Firewall lifecycle behavior'
bash "$LIFECYCLE_TEST"
bash "$FIREWALL_CONCURRENCY_TEST"
bash "$FIREWALL_SAFETY_TEST"
bash "$RPC_FIREWALL_TEST"
bash "$CLEANUP_FAILURE_TEST"
bash "$RUNTIME_STATUS_TEST"
bash "$AP_RESOLVER_TEST"

echo 'host tests: PASS'
