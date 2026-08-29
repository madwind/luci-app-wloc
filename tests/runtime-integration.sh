#!/bin/sh
set -eu

phase() {
    printf '[%s] %s\n' "$1" "$2"
}

if [ "${WLOC_RUNTIME_ALLOW_DESTRUCTIVE:-}" != 1 ]; then
    echo 'runtime integration: REFUSED (set WLOC_RUNTIME_ALLOW_DESTRUCTIVE=1 for a dedicated test device)' >&2
    exit 1
fi

if [ -z "${WLOC_OPENWRT_SSH:-}" ] || [ -z "${WLOC_OPENWRT_APK:-}" ]; then
    echo 'runtime integration: WLOC_OPENWRT_SSH and WLOC_OPENWRT_APK are required' >&2
    exit 1
fi

[ -f "$WLOC_OPENWRT_APK" ] || {
    echo "runtime integration: WLOC APK not found: $WLOC_OPENWRT_APK" >&2
    exit 1
}

for command in grep scp seq sleep ssh tail; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "runtime integration: required command not found: $command" >&2
        exit 1
    }
done

SSH_OPTIONS='-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1'
SCP_OPTIONS="$SSH_OPTIONS"
SSH_TARGET="$WLOC_OPENWRT_SSH"
REMOTE_APK='/tmp/luci-app-wloc-runtime.apk'
REMOTE_APPLY_RESULT='/tmp/wloc-runtime-apply-result'
PACKAGE_CLEANUP_REQUIRED=0
FIXTURE_CREATED=0
MAIN_ENABLED_WAS_SET=0
MAIN_ENABLED_VALUE=''
MAIN_DEBUG_WAS_SET=0
MAIN_DEBUG_VALUE=''

ssh_cmd() {
    ssh $SSH_OPTIONS "$SSH_TARGET" "$@"
}

scp_cmd() {
    scp $SCP_OPTIONS "$@"
}

fail() {
    echo "runtime integration: FAIL: $*" >&2
    echo '===== remote diagnostics =====' >&2
    ssh_cmd "/etc/init.d/wloc status" >&2 || true
    ssh_cmd "ubus call service list '{\"name\":\"wloc\"}'" >&2 || true
    ssh_cmd "ubus call luci.wloc status" >&2 || true
    ssh_cmd "logread -e wlocd | tail -n 80" >&2 || true
    ssh_cmd "nft list tables" >&2 || true
    ssh_cmd "nft list table inet wloc" >&2 || true
    ssh_cmd "uci show wloc" >&2 || true
    echo '===== end remote diagnostics =====' >&2
    exit 1
}

restore_main_enabled() {
    if [ "$MAIN_ENABLED_WAS_SET" -eq 1 ] && [ -n "$MAIN_ENABLED_VALUE" ]; then
        ssh_cmd "uci -q set wloc.main.enabled=$MAIN_ENABLED_VALUE; uci -q commit wloc" >/dev/null 2>&1 || true
    else
        ssh_cmd "uci -q delete wloc.main.enabled; uci -q commit wloc" >/dev/null 2>&1 || true
    fi
}

restore_main_debug() {
    if [ "$MAIN_DEBUG_WAS_SET" -eq 1 ] && [ -n "$MAIN_DEBUG_VALUE" ]; then
        ssh_cmd "uci -q set wloc.main.debug=$MAIN_DEBUG_VALUE; uci -q commit wloc" >/dev/null 2>&1 || true
    else
        ssh_cmd "uci -q delete wloc.main.debug; uci -q commit wloc" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    status=$?
    trap - EXIT INT TERM HUP

    if [ "$PACKAGE_CLEANUP_REQUIRED" -eq 1 ]; then
        ssh_cmd "/etc/init.d/wloc stop" >/dev/null 2>&1 || true
    fi

    if [ "$FIXTURE_CREATED" -eq 1 ]; then
        ssh_cmd "uci -q delete wireless.wloc_test; uci -q commit wireless" >/dev/null 2>&1 || true
        ssh_cmd "uci -q delete wloc.test; uci -q commit wloc" >/dev/null 2>&1 || true
        restore_main_enabled
        restore_main_debug
    fi

    if [ "$PACKAGE_CLEANUP_REQUIRED" -eq 1 ]; then
        ssh_cmd "apk del luci-app-wloc" >/dev/null 2>&1 || true
    fi

    ssh_cmd "rm -f $REMOTE_APK $REMOTE_APPLY_RESULT" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

service_value() {
    local path="$1"
    ssh_cmd "ubus call service list '{\"name\":\"wloc\"}' | jsonfilter -e '$path'"
}

instance_running() {
    local instance="$1" value
    value="$(service_value "@.wloc.instances.${instance}.running" 2>/dev/null || true)"
    case "$value" in
        true|1|yes) return 0;;
        *) return 1;;
    esac
}

daemon_pid() {
    service_value '@.wloc.instances.daemon.pid'
}

rpc_value() {
    local command="$1" path="$2"
    ssh_cmd "$command | jsonfilter -e '$path'"
}

wait_for_instance() {
    local instance="$1" attempt
    for attempt in $(seq 1 30); do
        if instance_running "$instance"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

reboot_device() {
    local attempt went_down=0

    phase REBOOT 'requesting device reboot'
    ssh_cmd reboot >/dev/null 2>&1 || true

    phase REBOOT 'waiting for device down'
    for attempt in $(seq 1 30); do
        if ! ssh_cmd true >/dev/null 2>&1; then
            went_down=1
            phase REBOOT 'device down'
            break
        fi
        sleep 1
    done

    [ "$went_down" -eq 1 ] || fail 'OpenWrt SSH never went down during reboot'

    phase REBOOT 'waiting for device up'
    for attempt in $(seq 1 90); do
        if ssh_cmd true >/dev/null 2>&1; then
            phase REBOOT 'device up'
            phase REBOOT 'waiting for WLOC instances'
            wait_for_instance daemon || fail 'WLOC daemon did not return after reboot'
            wait_for_instance schedule || fail 'WLOC schedule did not return after reboot'
            phase REBOOT 'WLOC instances restored'
            return 0
        fi
        sleep 2
    done

    fail 'OpenWrt SSH did not return after reboot'
}

phase PREFLIGHT 'checking SSH transport and remote tools'
ssh_cmd true >/dev/null 2>&1 || fail 'unable to connect to OpenWrt over SSH'
for command in apk ubus jsonfilter uci nft; do
    ssh_cmd "command -v $command >/dev/null 2>&1" \
        || fail "required OpenWrt command not found: $command"
done

if ssh_cmd "apk info -e luci-app-wloc >/dev/null 2>&1"; then
    fail 'luci-app-wloc is already installed; use a dedicated clean test device'
fi
if ssh_cmd "uci -q get wireless.wloc_test >/dev/null 2>&1"; then
    fail 'wireless.wloc_test already exists; refusing to modify an existing AP section'
fi
if ssh_cmd "uci -q get wloc.test >/dev/null 2>&1"; then
    fail 'wloc.test already exists; refusing to modify an existing location section'
fi

if MAIN_ENABLED_VALUE="$(ssh_cmd "uci -q get wloc.main.enabled" 2>/dev/null)"; then
    MAIN_ENABLED_WAS_SET=1
fi
if MAIN_DEBUG_VALUE="$(ssh_cmd "uci -q get wloc.main.debug" 2>/dev/null)"; then
    MAIN_DEBUG_WAS_SET=1
fi
case "$MAIN_ENABLED_VALUE" in
    ''|*[!A-Za-z0-9_.-]*)
        [ "$MAIN_ENABLED_WAS_SET" -eq 0 ] || fail 'wloc.main.enabled has an unsafe value to restore';;
esac
case "$MAIN_DEBUG_VALUE" in
    ''|*[!A-Za-z0-9_.-]*)
        [ "$MAIN_DEBUG_WAS_SET" -eq 0 ] || fail 'wloc.main.debug has an unsafe value to restore';;
esac

phase APK 'installing package'
scp_cmd "$WLOC_OPENWRT_APK" "$SSH_TARGET:$REMOTE_APK" >/dev/null \
    || fail 'unable to copy the WLOC APK to OpenWrt'
PACKAGE_CLEANUP_REQUIRED=1
ssh_cmd "apk add --allow-untrusted $REMOTE_APK" >/dev/null \
    || fail 'apk could not install luci-app-wloc'
ssh_cmd "command -v rpcd >/dev/null && [ -x /etc/init.d/wloc ]" \
    || fail 'package install did not provide rpcd or the wloc init script'
phase APK 'WLOC installed'

phase PROCD 'verifying default_postinst'
ssh_cmd /etc/init.d/wloc enabled \
    || fail 'OpenWrt default_postinst did not enable wloc'
wait_for_instance schedule \
    || fail 'OpenWrt default_postinst did not start the WLOC schedule instance'
if instance_running daemon; then
    fail 'WLOC daemon started while main.enabled was still 0'
fi
phase PROCD 'default_postinst verified'

FIXTURE_CREATED=1
ssh_cmd "uci set wireless.wloc_test=wifi-iface; uci set wireless.wloc_test.mode=ap; uci set wireless.wloc_test.ifname=lo; uci set wireless.wloc_test.ssid=wloc-test; uci set wloc.test=wifi; uci set wloc.test.enabled=1; uci set wloc.test.iface=lo; uci set wloc.test.latitude=0; uci set wloc.test.longitude=0; uci set wloc.test.proxy_type=direct; uci set wloc.main.enabled=1; uci commit wireless; uci commit wloc" \
    || fail 'could not create the deterministic WLOC test fixture'
ssh_cmd /etc/init.d/wloc restart >/dev/null \
    || fail 'wloc could not be restarted after enabling the daemon'

instance_running daemon \
    || fail 'procd daemon instance is not running'
instance_running schedule \
    || fail 'procd schedule instance is not running'
ssh_cmd ubus call luci.wloc status >/dev/null \
    || fail 'luci.wloc status RPC failed'
phase PROCD 'service verified'

phase FIREWALL 'applying unsaved rules'
persistent_a="$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")"
FIREWALL_B='table inet wloc { set apple_wloc_v4 { type ipv4_addr; flags timeout; }; }'
APPLY_COMMAND="ubus call luci.wloc firewall_apply '{\"config\":\"$FIREWALL_B\"}'"
ssh_cmd "$APPLY_COMMAND > $REMOTE_APPLY_RESULT" \
    || fail 'firewall Apply did not return a response'
apply_ok="$(rpc_value "cat $REMOTE_APPLY_RESULT" '@.ok' 2>/dev/null || true)"
case "$apply_ok" in
    true|1) ;;
    *) ssh_cmd "cat $REMOTE_APPLY_RESULT" >&2 || true
       fail 'firewall Apply did not return ok=true';;
esac
applied_hash="$(rpc_value "cat $REMOTE_APPLY_RESULT" '@.applied_hash')"
[ -n "$applied_hash" ] || fail 'firewall Apply did not return an applied revision'
ssh_cmd "rm -f $REMOTE_APPLY_RESULT"
ssh_cmd "nft list table inet wloc >/dev/null" \
    || fail 'applied firewall rules are not active'
[ "$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")" = "$persistent_a" ] \
    || fail 'Apply changed the persistent firewall file'
phase FIREWALL 'Apply without Save'
reboot_device
[ "$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")" = "$persistent_a" ] \
    || fail 'reboot without Save did not restore the persistent firewall file'
if ssh_cmd "nft list table inet wloc >/dev/null 2>&1"; then
    fail 'unsaved firewall rules survived reboot'
fi
phase FIREWALL 'rollback verified'

phase FIREWALL 'applying and saving rules'
ssh_cmd "$APPLY_COMMAND > $REMOTE_APPLY_RESULT" \
    || fail 'second firewall Apply did not return a response'
apply_ok="$(rpc_value "cat $REMOTE_APPLY_RESULT" '@.ok' 2>/dev/null || true)"
case "$apply_ok" in
    true|1) ;;
    *) ssh_cmd "cat $REMOTE_APPLY_RESULT" >&2 || true
       fail 'second firewall Apply did not return ok=true';;
esac
applied_hash="$(rpc_value "cat $REMOTE_APPLY_RESULT" '@.applied_hash')"
[ -n "$applied_hash" ] || fail 'second firewall Apply did not return an applied revision'
ssh_cmd "rm -f $REMOTE_APPLY_RESULT"
SAVE_COMMAND="ubus call luci.wloc firewall_save '{\"expected_applied_hash\":\"$applied_hash\"}'"
case "$(rpc_value "$SAVE_COMMAND" '@.ok')" in
    true|1) ;;
    *) fail 'firewall Save did not return ok=true';;
esac
persistent_b="$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")"
[ "$persistent_b" != "$persistent_a" ] \
    || fail 'Save did not replace the persistent firewall file'
reboot_device
[ "$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")" = "$persistent_b" ] \
    || fail 'saved firewall rules did not survive reboot'
ssh_cmd "nft list table inet wloc >/dev/null" \
    || fail 'saved firewall table was not restored after reboot'
phase FIREWALL 'Save verified'

daemon_pid="$(daemon_pid 2>/dev/null || true)"
case "$daemon_pid" in
    *[!0-9]*|'') fail 'could not find the procd-managed wlocd PID';;
esac

phase PROCD 'testing crash recovery'
ssh_cmd "kill -9 $daemon_pid" >/dev/null \
    || fail 'could not terminate the procd-managed daemon'
recovered=0
for attempt in $(seq 1 30); do
    new_pid="$(daemon_pid 2>/dev/null || true)"
    if instance_running daemon && [ "$new_pid" != "$daemon_pid" ] && printf '%s' "$new_pid" | grep -Eq '^[0-9]+$'; then
        recovered=1
        break
    fi
    sleep 1
done
[ "$recovered" -eq 1 ] || fail 'procd did not respawn wlocd'
ssh_cmd "logread -e wlocd" | grep -q 'wlocd:' \
    || fail 'wlocd stderr was not visible in logread'
phase PROCD 'respawn verified'

phase PROCD 'testing config reload'
reload_pid="$new_pid"
ssh_cmd "uci set wloc.main.debug=1; uci commit wloc; ubus call service event '{\"type\":\"config.change\",\"data\":{\"package\":\"wloc\"}}'" \
    || fail 'service config reload failed'
reloaded=0
for attempt in $(seq 1 30); do
    new_reload_pid="$(daemon_pid 2>/dev/null || true)"
    if instance_running daemon && [ "$new_reload_pid" != "$reload_pid" ]; then
        reloaded=1
        break
    fi
    sleep 1
done
[ "$reloaded" -eq 1 ] || fail 'wloc daemon did not reload after config change'
ssh_cmd ubus call luci.wloc status >/dev/null \
    || fail 'status RPC failed after service reload'
phase PROCD 'config reload verified'

phase STOP 'stopping service'
ssh_cmd /etc/init.d/wloc stop >/dev/null \
    || fail 'wloc could not be stopped'
if instance_running daemon || instance_running schedule; then
    fail 'a WLOC procd instance remained running after stop'
fi
if ssh_cmd "nft list set inet wloc apple_wloc_v4 2>/dev/null | grep -Eq 'elements[[:space:]]*=[[:space:]]*\\{[^}0-9]*[0-9]'"; then
    fail 'WLOC dynamic host-set elements remained after stop'
fi
phase STOP 'service stopped and dynamic state removed'

phase UNINSTALL 'removing package while running'
ssh_cmd /etc/init.d/wloc start >/dev/null \
    || fail 'wloc could not be started before uninstall'
wait_for_instance daemon \
    || fail 'WLOC daemon did not start before uninstall'
wait_for_instance schedule \
    || fail 'WLOC schedule did not start before uninstall'
ssh_cmd "nft list table inet wloc >/dev/null" \
    || fail 'WLOC firewall table was not active before uninstall'
ssh_cmd "test -s /var/run/wloc/firewall.applied.nft" \
    || fail 'runtime firewall snapshot was not present before uninstall'
ssh_cmd "apk del luci-app-wloc" >/dev/null \
    || fail 'apk could not uninstall luci-app-wloc'
PACKAGE_CLEANUP_REQUIRED=0
if instance_running daemon || instance_running schedule; then
    fail 'a WLOC procd instance remained running after package uninstall'
fi
ssh_cmd "test ! -x /etc/init.d/wloc" \
    || fail 'WLOC init service remained after package uninstall'
if ssh_cmd "nft list table inet wloc >/dev/null 2>&1"; then
    fail 'WLOC nftables table remained after package uninstall'
fi
ssh_cmd "test ! -e /var/run/wloc/firewall.applied.nft" \
    || fail 'applied firewall snapshot remained after package uninstall'
ssh_cmd "test ! -e /var/run/wloc/firewall.applied.nft.next" \
    || fail 'staged firewall snapshot remained after package uninstall'
ssh_cmd "test ! -e /var/run/wloc/status.json && test ! -e /var/run/wloc/runtime.log && test ! -e /var/run/wloc/start-error" \
    || fail 'WLOC runtime state remained after package uninstall'
ssh_cmd "lock -n /var/lock/wloc-firewall.lock" \
    || fail 'firewall lock remained held after package uninstall'
ssh_cmd "lock -u /var/lock/wloc-firewall.lock" \
    || fail 'firewall lock could not be released after uninstall verification'
phase UNINSTALL 'cleanup verified'

phase COMPLETE 'all runtime integration checks passed'
echo 'OpenWrt runtime integration: PASS'
