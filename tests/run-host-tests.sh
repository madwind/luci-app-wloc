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
FIREWALL_REMOVE_TEST="$ROOT/tests/firewall-remove-lifecycle.test.sh"
FIREWALL_SAFETY_TEST="$ROOT/tests/firewall-command-safety.test.sh"
RPC_FIREWALL_TEST="$ROOT/tests/rpc-firewall-lifecycle.test.sh"
CLEANUP_FAILURE_TEST="$ROOT/tests/cleanup-failure.test.sh"
FIREWALL_UI_TEST="$ROOT/tests/firewall-ui.test.js"
FIREWALL_VIEW="$HTDOCS/luci-static/resources/view/wloc/firewall.js"
MAIN_VIEW="$HTDOCS/luci-static/resources/view/wloc/main.js"
STATUS_SOURCE="$ROOT/src/wloc-rs/src/status.rs"
RUNTIME_INTEGRATION_TEST="$ROOT/tests/runtime-integration.sh"

fail() {
    echo "host tests: FAIL: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 \
        || fail "required command not found: $1"
}

for command in sh find python3 node sed awk; do
    need "$command"
done

[ -d "$ROOTFS" ] || fail "root directory not found"
[ -d "$HTDOCS" ] || fail "htdocs directory not found"
[ -f "$RULES" ] || fail "rules.sh not found"
[ -f "$FIREWALL_HELPER" ] || fail "firewall.sh not found"
[ -f "$AP_TEST" ] || fail "AP discovery test not found"
[ -f "$AP_RESOLVER_TEST" ] || fail "AP resolver test not found"
[ -f "$LIFECYCLE_TEST" ] || fail "WLOC lifecycle test not found"
[ -f "$FIREWALL_CONCURRENCY_TEST" ] || fail "WLOC firewall concurrency test not found"
[ -f "$FIREWALL_REMOVE_TEST" ] || fail "WLOC firewall removal test not found"
[ -f "$FIREWALL_SAFETY_TEST" ] || fail "WLOC firewall command safety test not found"
[ -f "$RPC_FIREWALL_TEST" ] || fail "WLOC RPC firewall test not found"
[ -f "$CLEANUP_FAILURE_TEST" ] || fail "WLOC cleanup failure test not found"
[ -f "$FIREWALL_UI_TEST" ] || fail "WLOC firewall UI test not found"
[ -f "$FIREWALL_VIEW" ] || fail "WLOC firewall view not found"
[ -f "$MAIN_VIEW" ] || fail "WLOC main view not found"
[ -f "$STATUS_SOURCE" ] || fail "WLOC status source not found"
[ -f "$RUNTIME_INTEGRATION_TEST" ] || fail "OpenWrt runtime integration test not found"


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
sh -n "$RUNTIME_INTEGRATION_TEST" || fail "shell syntax error: $RUNTIME_INTEGRATION_TEST"


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
node "$FIREWALL_UI_TEST"


echo '==> Service startup behavior'

if grep -Eq '^define Package/luci-app-wloc/postinst$' "$ROOT/Makefile"; then
    fail 'package Makefile still overrides the standard LuCI postinst'
fi
if grep -Eq '/etc/init.d/wloc (enable|start|disable)' "$ROOT/Makefile"; then
    fail 'package hooks still duplicate standard enable/start/disable actions'
fi
prerm_cleanup_line="$(grep -nF 'firewall.sh remove-runtime' "$ROOT/Makefile" | cut -d: -f1 | head -n 1)"
if grep -Fq '/etc/init.d/wloc stop' "$ROOT/Makefile"; then
    fail 'package prerm duplicates the standard service stop lifecycle'
fi
[ -n "$prerm_cleanup_line" ] \
    || fail 'package prerm does not clean up WLOC firewall state'
SMOKE_WORKFLOW="$ROOT/.github/workflows/openwrt-smoke.yml"
[ -f "$SMOKE_WORKFLOW" ] \
    || fail 'x86_64 SDK smoke workflow is missing'
grep -Fq 'x86_64 SDK compile smoke' "$SMOKE_WORKFLOW" \
    || fail 'x86_64 SDK smoke workflow is missing its job'
grep -Fq 'scripts/build-openwrt-*.sh' "$SMOKE_WORKFLOW" \
    || fail 'x86_64 SDK smoke workflow does not filter build-source changes'
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
grep -Fq 'FIREWALL_RUNTIME_WARNING' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not expose reconcile recovery state'
grep -Fq 'runtime_ready' "$RPC" \
    || fail 'firewall RPC does not expose runtime readiness'
grep -Fq 'recovering' "$RPC" \
    || fail 'firewall RPC does not expose recovery state'
grep -Fq 'remove-runtime' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not expose runtime table cleanup'
grep -Fq 'firewall.sh remove-runtime' "$ROOT/Makefile" \
    || fail 'package prerm does not clean up runtime nftables tables'
grep -Fq 'firewall_active' "$RPC" \
    || fail 'status RPC does not expose live firewall activity'
grep -Fq 'FIREWALL_RUNTIME_PROMOTION_FAILED' "$RPC" \
    || fail 'firewall RPC does not expose fatal snapshot promotion failures'
grep -Fq 'FIREWALL_LOCK_TIMEOUT' "$FIREWALL_HELPER" \
    || fail 'firewall lock does not have a bounded wait'
grep -Fq 'FIREWALL_LOCK=${WLOC_FIREWALL_LOCK:-/var/lock/wloc-firewall.lock}' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not use the OpenWrt lock path'
grep -Fq 'FIREWALL_LOCK_COMMAND=${WLOC_FIREWALL_LOCK_COMMAND:-lock}' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not use the OpenWrt lock utility'
grep -Fq '"$FIREWALL_LOCK_COMMAND" -n "$FIREWALL_LOCK"' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not acquire the lock non-blocking'
grep -Fq '"$FIREWALL_LOCK_COMMAND" -u "$FIREWALL_LOCK"' "$FIREWALL_HELPER" \
    || fail 'firewall helper does not release the native lock'
if grep -Eq 'firewall_process_start|firewall_lock_(save_traps|restore_trap|abort|install_traps|owner_alive|remove_stale)|FIREWALL_LOCK_OWNER|trap -p|/owner' "$FIREWALL_HELPER"; then
    fail 'firewall helper still contains the removed custom owner/trap lock'
fi
grep -Fq 'LUCI_DEPENDS:=@(aarch64||x86_64)' "$ROOT/Makefile" \
    || fail 'package Makefile does not declare supported architectures'
grep -Fq 'LUCI_EXTRA_DEPENDS:=' "$ROOT/Makefile" \
    || fail 'package Makefile no longer separates runtime-only dependencies'
grep -Fq 'luci-base (>=0)' "$ROOT/Makefile" \
    || fail 'runtime-only luci-base dependency is missing'
grep -Fq 'nftables (>=0)' "$ROOT/Makefile" \
    || fail 'runtime-only nftables dependency is missing'
grep -Fq 'jshn (>=0)' "$ROOT/Makefile" \
    || fail 'runtime-only jshn dependency is missing'
if grep -Fq 'ip-full (>=0)' "$ROOT/Makefile"; then
    fail 'unused ip-full runtime dependency is still declared'
fi

grep -Fq 'listener_ready' "$INIT" \
    || fail 'service start does not defer dynamic-set population until listener readiness'
grep -Fq 'firewall.applied.nft' "$INIT" \
    || fail 'service start does not clear the volatile applied firewall snapshot'
grep -Fq 'firewall.applied.nft.next' "$INIT" \
    || fail 'service start does not clear the staged firewall snapshot'
grep -Fq 'firewall.applied.nft' "$INIT" \
    || fail 'service start does not clear the volatile applied firewall snapshot'
grep -Fq 'firewall.applied.nft.next' "$INIT" \
    || fail 'service start does not clear the staged firewall snapshot'
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

echo '==> Runtime log behavior'

grep -Fq 'const MAX_LOG_LINES: usize = 240;' "$STATUS_SOURCE" \
    || fail 'runtime log does not define a line bound'
grep -Fq 'const MAX_LOG_BYTES: usize = 96 * 1024;' "$STATUS_SOURCE" \
    || fail 'runtime log does not define a byte bound'
grep -Fq 'const MAX_LOG_LINE_CHARS: usize = 600;' "$STATUS_SOURCE" \
    || fail 'runtime log does not define a line-length bound'
grep -Fq 'safe_text(detail, MAX_LOG_LINE_CHARS)' "$STATUS_SOURCE" \
    || fail 'runtime log does not bound event line length'
grep -Fq 'while inner.logs.len() > MAX_LOG_LINES || inner.log_bytes > MAX_LOG_BYTES' "$STATUS_SOURCE" \
    || fail 'runtime log does not evict entries at its configured bounds'
grep -Fq 'runtime_log_revision' "$RPC" \
    || fail 'status RPC does not expose the runtime log revision'
grep -Fq 'lastLogRevision' "$MAIN_VIEW" \
    || fail 'LuCI does not retain the last runtime log revision'
grep -Fq 'revision === lastLogRevision' "$MAIN_VIEW" \
    || fail 'LuCI runtime log polling is not revision based'
grep -Fq 'poll.add(refresh, 10)' "$MAIN_VIEW" \
    || fail 'LuCI status polling is not configured'
if grep -REq 'logread[[:space:]]+(-f|--follow)' "$RPC" "$MAIN_VIEW"; then
    fail 'runtime log UI still uses a long-running logread stream'
fi

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
sh "$FIREWALL_CONCURRENCY_TEST"
sh "$FIREWALL_REMOVE_TEST"
sh "$FIREWALL_SAFETY_TEST"
sh "$RPC_FIREWALL_TEST"
sh "$CLEANUP_FAILURE_TEST"

echo '==> nftables editor behavior'

grep -Fq 'unsupported_firewall_command' "$FIREWALL_HELPER" "$RPC" \
    || fail 'firewall command safety error is not exposed by the backend'
grep -Fq 'unsupported_firewall_command' "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" \
    || fail 'LuCI does not map the unsupported firewall command error'
grep -Fq 'Only declarative nftables table definitions are supported.' "$RPC" \
    || fail 'backend does not explain the declarative firewall boundary'
grep -F 'nft --check --file' "$FIREWALL_HELPER" >/dev/null \
    || fail 'nftables editor no longer performs a syntax-only check'
grep -F 'expected_applied_hash' "$RPC" "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" >/dev/null \
    || fail 'firewall Save does not require the applied revision'
if grep -Fq "callSave(editor.value)" "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js"; then
    fail 'firewall save still accepts un-applied editor contents'
fi
grep -F 'callApply(editor.value)' "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" >/dev/null \
    || fail 'firewall apply does not receive editor contents'
grep -F 'initialEditorContent(result)' "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" >/dev/null \
    || fail 'firewall refresh does not restore applied rules'
grep -Fq 'editor.value = initialEditorContent(result);' "$FIREWALL_VIEW" \
    || fail 'firewall reload does not put the applied rules back in the editor'
grep -Fq 'callSave(appliedRevision)' "$FIREWALL_VIEW" \
    || fail 'firewall Save does not send the applied revision'
grep -F 'savedHash = persistentPresent ? String(result.saved_hash ||' "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js" >/dev/null \
    || fail 'firewall refresh does not keep the persistent hash separate from the editor'
if grep -REq 'FIREWALL_CANDIDATE|firewall\.candidate\.nft|candidate_hash|candidate_present' \
    "$FIREWALL_HELPER" "$RPC" "$INIT" "$ROOT/htdocs/luci-static/resources/view/wloc/firewall.js"; then
    fail 'removed runtime candidate snapshot is still part of the firewall lifecycle'
fi
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


echo '  -> unrestricted nftables rules'

if grep -Eq 'table_healthy|bridge_table_healthy|ensure_table_healthy' "$RULES"; then
    fail 'rules.sh still enforces a fixed nftables table layout'
fi

grep -F 'ingress_set_targets()' "$RULES" >/dev/null \
    || fail 'rules.sh no longer discovers optional ingress sets'


echo '  -> fixed-interface ingress synchronization'

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

nft() {
    if [ "${1:-}" = '-f' ] && [ "${2:-}" = '-' ]; then
        if [ -n "${WLOC_TEST_NFT_BATCH_LOG:-}" ]; then
            cat >>"$WLOC_TEST_NFT_BATCH_LOG"
        else
            cat
        fi
        return 0
    fi
    if [ "${1:-}" = list ] && [ "${2:-}" = set ] && [ "${5:-}" = apple_wloc_v4 ]; then
        case "${4:-}" in
            host_missing)
                return 1
                ;;
            host_incompatible)
                printf '%s\n' 'type inet_service' 'flags timeout'
                return 0
                ;;
            host_compatible)
                printf '%s\n' 'type ipv4_addr' 'flags timeout'
                return 0
                ;;
            host_mixed_bad)
                printf '%s\n' 'type inet_service' 'flags timeout'
                return 0
                ;;
            host_mixed_good)
                printf '%s\n' 'type ipv4_addr' 'flags timeout'
                return 0
                ;;
            host_concatenated)
                printf '%s\n' 'type ipv4_addr . inet_service' 'flags timeout'
                return 0
                ;;
            host_resolve_good)
                printf '%s\n' 'type ipv4_addr' 'flags timeout'
                return 0
                ;;
            host_resolve_bad)
                printf '%s\n' 'type inet_service' 'flags timeout'
                return 0
                ;;
        esac
    fi
    if [ "${1:-}" = add ] && [ "${2:-}" = element ] && [ "${5:-}" = apple_wloc_v4 ]; then
        if [ -n "${WLOC_TEST_HOST_ADD_LOG:-}" ]; then
            printf '%s\n' "$*" >>"$WLOC_TEST_HOST_ADD_LOG"
        fi
        return 0
    fi
    if [ "${1:-}" = flush ] && [ "${5:-}" = apple_wloc_v4 ]; then
        printf '%s\n' "$*" >>"$host_flush_log"
        return 0
    fi
    if [ "${1:-}" = list ] && [ "${2:-}" = set ] && [ "${5:-}" = target_ingress_interfaces ]; then
        if [ "${4:-}" = missing ]; then
            return 1
        fi
        if [ "${4:-}" = incompatible ]; then
            printf '%s\n' 'type ipv4_addr' 'flags timeout'
            return 0
        fi
        if [ "${4:-}" = mixed_bad ]; then
            printf '%s\n' 'type ipv4_addr' 'flags timeout'
            return 0
        fi
        printf '%s\n' 'type ifname' 'flags timeout'
        return 0
    fi
    return 1
}

nslookup() {
    printf '%s\n' 'Name: gs-loc.apple.com' 'Address: 1.2.3.4'
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

ingress_snapshot="$fixture_root/firewall.applied.nft"
ingress_persistent="$fixture_root/firewall.persistent.nft"
printf '%s\n' \
    'table bridge custom_wloc {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_snapshot"
printf '%s\n' 'table bridge persistent_wloc { }' >"$ingress_persistent"
CUSTOM_FIREWALL="$ingress_snapshot"
PERSISTENT_FIREWALL="$ingress_persistent"
[ "$(ingress_set_targets)" = 'bridge custom_wloc' ] \
    || fail 'ingress discovery did not find a custom table in the applied snapshot'
expected_custom_ingress_batch='flush set bridge custom_wloc target_ingress_interfaces
add element bridge custom_wloc target_ingress_interfaces { "phy0-ap0" timeout 120s }
add element bridge custom_wloc target_ingress_interfaces { "phy1-ap0" timeout 120s }'
[ "$(sync_ingress_interfaces)" = "$expected_custom_ingress_batch" ] \
    || fail 'custom-table ingress synchronization generated an unexpected batch'

printf '%s\n' \
    'table bridge foo {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet bar {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_snapshot"
expected_multi_ingress_batch='flush set bridge foo target_ingress_interfaces
add element bridge foo target_ingress_interfaces { "phy0-ap0" timeout 120s }
add element bridge foo target_ingress_interfaces { "phy1-ap0" timeout 120s }
flush set inet bar target_ingress_interfaces
add element inet bar target_ingress_interfaces { "phy0-ap0" timeout 120s }
add element inet bar target_ingress_interfaces { "phy1-ap0" timeout 120s }'
[ "$(sync_ingress_interfaces)" = "$expected_multi_ingress_batch" ] \
    || fail 'multiple ingress sets were not synchronized in one transaction'

printf '%s\n' \
    'table bridge incompatible {' \
    '    set target_ingress_interfaces {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_snapshot"
if sync_ingress_interfaces; then
    fail 'incompatible ingress set was treated as compatible'
fi

ingress_batch_log="$fixture_root/mixed-ingress-batch.log"
printf '%s\n' \
    'table bridge mixed_good {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet mixed_bad {' \
    '    set target_ingress_interfaces {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_snapshot"
: >"$ingress_batch_log"
WLOC_TEST_NFT_BATCH_LOG="$ingress_batch_log"
if sync_ingress_interfaces; then
    fail 'mixed ingress sets were reported as successfully reconciled'
fi
unset WLOC_TEST_NFT_BATCH_LOG
[ ! -s "$ingress_batch_log" ] \
    || fail 'mixed ingress sets were partially updated'

rm -f "$ingress_snapshot"
printf '%s\n' \
    'table bridge fallback_wloc {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_persistent"
[ "$(ingress_set_targets)" = 'bridge fallback_wloc' ] \
    || fail 'ingress discovery did not fall back to the persistent snapshot'

printf '%s\n' \
    'table bridge missing {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_snapshot"
[ -z "$(sync_ingress_interfaces)" ] \
    || fail 'an ingress set missing from nftables state was not skipped'

printf '%s\n' 'table bridge no_ingress { }' >"$ingress_snapshot"
[ -z "$(sync_ingress_interfaces)" ] \
    || fail 'missing optional ingress set prevented reconciliation'

CUSTOM_FIREWALL="$ingress_snapshot"
PERSISTENT_FIREWALL="$ingress_persistent"
printf '%s\n' \
    'table bridge wloc {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$ingress_snapshot"
[ "$(sync_ingress_interfaces)" = "$expected_ingress_batch" ] \
    || fail 'fixed-interface ingress synchronization generated an unexpected batch'

echo '  -> host-set cleanup preserves type safety'
host_flush_log="$fixture_root/host-set-flush.log"
host_snapshot="$fixture_root/host-set.applied.nft"
host_persistent="$fixture_root/host-set.persistent.nft"
: >"$host_persistent"

printf '%s\n' \
    'table inet host_compatible {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
CUSTOM_FIREWALL="$host_snapshot"
PERSISTENT_FIREWALL="$host_persistent"
: >"$host_flush_log"
clear_host_sets \
    || fail 'compatible host set cleanup failed'
grep -Fqx 'flush set inet host_compatible apple_wloc_v4' "$host_flush_log" \
    || fail 'compatible host set was not flushed'

printf '%s\n' \
    'table inet host_incompatible {' \
    '    set apple_wloc_v4 {' \
    '        type inet_service' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_flush_log"
if clear_host_sets; then
    fail 'incompatible host set cleanup was reported as successful'
fi
[ ! -s "$host_flush_log" ] \
    || fail 'incompatible host set was flushed'

printf '%s\n' \
    'table inet host_concatenated {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr . inet_service' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_flush_log"
if clear_host_sets; then
    fail 'concatenated host set cleanup was reported as successful'
fi
[ ! -s "$host_flush_log" ] \
    || fail 'concatenated host set was flushed'

echo '  -> host-set reconciliation skips missing runtime targets'
host_add_log="$fixture_root/host-set-add.log"
WLOC_TEST_HOST_ADD_LOG="$host_add_log"
STAMP="$fixture_root/hosts.refreshed"
DNS_ATTEMPT_STAMP="$fixture_root/hosts.attempted"
DNS_REFRESH_SECONDS=0
DNS_RETRY_SECONDS=0

printf '%s\n' \
    'table inet host_resolve_good {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet host_resolve_missing {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_add_log"
resolve_hosts \
    || fail 'compatible host target did not survive a missing runtime target'
grep -Fq 'add element inet host_resolve_good apple_wloc_v4' "$host_add_log" \
    || fail 'compatible host target was not refreshed'
if grep -Fq 'host_resolve_missing' "$host_add_log"; then
    fail 'missing host target was unexpectedly maintained'
fi

printf '%s\n' \
    'table inet host_all_missing_a {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet host_all_missing_b {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_add_log"
if resolve_hosts; then
    fail 'all missing host targets were reported as successfully reconciled'
fi
[ ! -s "$host_add_log" ] \
    || fail 'all missing host targets were unexpectedly maintained'

printf '%s\n' \
    'table inet host_resolve_good {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet host_resolve_bad {' \
    '    set apple_wloc_v4 {' \
    '        type inet_service' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_add_log"
if resolve_hosts; then
    fail 'mixed compatible/incompatible host targets were reported as successful'
fi
grep -Fq 'add element inet host_resolve_good apple_wloc_v4' "$host_add_log" \
    || fail 'compatible host target was not refreshed in a mixed reconciliation'
if grep -Fq 'host_resolve_bad' "$host_add_log"; then
    fail 'incompatible host target was unexpectedly maintained'
fi

printf '%s\n' \
    'table inet host_missing {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_flush_log"
clear_host_sets \
    || fail 'missing host set made cleanup fail'
[ ! -s "$host_flush_log" ] \
    || fail 'missing host set unexpectedly received a flush'

printf '%s\n' \
    'table inet host_mixed_good {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet host_mixed_bad {' \
    '    set apple_wloc_v4 {' \
    '        type inet_service' \
    '        flags timeout' \
    '    }' \
    '}' >"$host_snapshot"
: >"$host_flush_log"
if clear_host_sets; then
    fail 'mixed host-set cleanup was reported as successful'
fi
grep -Fqx 'flush set inet host_mixed_good apple_wloc_v4' "$host_flush_log" \
    || fail 'compatible host set was not processed when another target was incompatible'
if grep -Fqx 'flush set inet host_mixed_bad apple_wloc_v4' "$host_flush_log"; then
    fail 'incompatible host set was flushed in a mixed cleanup'
fi

echo '  -> empty applied snapshots take precedence over persistent rules'
empty_applied_snapshot="$fixture_root/empty-firewall.applied.nft"
old_persistent_snapshot="$fixture_root/old-firewall.nft"
: >"$empty_applied_snapshot"
printf '%s\n' \
    'table inet old {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$old_persistent_snapshot"
CUSTOM_FIREWALL="$empty_applied_snapshot"
PERSISTENT_FIREWALL="$old_persistent_snapshot"
[ "$(firewall_snapshot)" = "$empty_applied_snapshot" ] \
    || fail 'empty applied snapshot did not take precedence'
[ -z "$(ingress_set_targets)" ] \
    || fail 'ingress targets were read from persistent rules after an empty Apply'
[ -z "$(declarative_set_targets "$HOST_SET")" ] \
    || fail 'host declarations were read from persistent rules after an empty Apply'
[ -z "$(host_set_targets)" ] \
    || fail 'host targets retained a legacy fallback after an empty Apply'

nft() { return 1; }


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
