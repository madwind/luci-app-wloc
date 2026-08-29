#!/bin/sh
set -eu

fail() {
    echo "OpenWrt lifecycle tests: FAIL: $*" >&2

    if [ -n "${QEMU_PID:-}" ]; then
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            echo 'QEMU process is still running.' >&2
        else
            echo 'QEMU process is no longer running.' >&2
        fi
    fi

    if [ -n "${CONSOLE_LOG:-}" ] &&
       [ -s "$CONSOLE_LOG" ]; then
        echo '===== QEMU console tail =====' >&2
        tail -n 300 "$CONSOLE_LOG" >&2
        echo '===== end QEMU console =====' >&2
    fi

    exit 1
}

phase() {
    printf '[%s] %s\n' "$1" "$2"
}

if [ -z "${WLOC_OPENWRT_IMAGE:-}" ] || [ -z "${WLOC_OPENWRT_APK:-}" ] || [ -z "${WLOC_OPENWRT_SSH_KEY:-}" ]; then
    echo 'OpenWrt lifecycle tests: SKIP (set WLOC_OPENWRT_IMAGE, WLOC_OPENWRT_APK, and WLOC_OPENWRT_SSH_KEY)'
    exit 0
fi

for command in basename grep qemu-system-x86_64 scp ssh seq sleep tail; do
    command -v "$command" >/dev/null 2>&1 \
        || fail "required command not found: $command"
done
[ -f "$WLOC_OPENWRT_IMAGE" ] || fail "OpenWrt image not found: $WLOC_OPENWRT_IMAGE"
[ -f "$WLOC_OPENWRT_APK" ] || fail "WLOC APK not found: $WLOC_OPENWRT_APK"
[ -f "$WLOC_OPENWRT_SSH_KEY" ] || fail "SSH key not found: $WLOC_OPENWRT_SSH_KEY"

SSH_PORT=${WLOC_OPENWRT_SSH_PORT:-22022}
MEMORY=${WLOC_OPENWRT_MEMORY:-256M}
SSH_TARGET="root@127.0.0.1"
SSH_OPTIONS="-i $WLOC_OPENWRT_SSH_KEY -p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=2 -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP_OPTIONS="-O -i $WLOC_OPENWRT_SSH_KEY -P $SSH_PORT -o BatchMode=yes -o ConnectTimeout=2 -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CONSOLE_LOG="$(mktemp)"
QEMU_PID=''

cleanup() {
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$CONSOLE_LOG"
}
trap cleanup EXIT INT TERM HUP

ssh_cmd() {
    ssh $SSH_OPTIONS "$SSH_TARGET" "$@"
}

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

wait_for_ssh() {
    local attempt
    for attempt in $(seq 1 60); do
        if ssh_cmd true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

reboot_guest() {
    local attempt went_down=0

    phase REBOOT 'requesting guest reboot'
    ssh_cmd reboot >/dev/null 2>&1 || true

    phase REBOOT 'waiting for guest down'
    for attempt in $(seq 1 30); do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            fail 'QEMU exited while OpenWrt was rebooting'
        fi

        if ! ssh_cmd true >/dev/null 2>&1; then
            went_down=1
            phase REBOOT 'guest down'
            break
        fi
        sleep 1
    done

    [ "$went_down" -eq 1 ] ||
        fail 'OpenWrt SSH never went down during reboot'

    phase REBOOT 'waiting for guest up'
    for attempt in $(seq 1 90); do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            fail 'QEMU exited before OpenWrt returned from reboot'
        fi

        if ssh_cmd true >/dev/null 2>&1; then
            phase REBOOT 'guest up'
            phase REBOOT 'waiting for WLOC instances'
            wait_for_instance daemon ||
                fail 'WLOC daemon did not return after reboot'
            wait_for_instance schedule ||
                fail 'WLOC schedule did not return after reboot'
            phase REBOOT 'WLOC instances restored'
            return 0
        fi

        sleep 2
    done

    fail 'OpenWrt SSH did not return after reboot'
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

apk_name="$(basename "$WLOC_OPENWRT_APK")"
qemu-system-x86_64 \
    -machine q35 \
    -m "$MEMORY" \
    -nographic \
    -drive "file=$WLOC_OPENWRT_IMAGE,format=raw,if=virtio" \
    -netdev "user,id=net0,net=192.168.1.0/24,hostfwd=tcp::$SSH_PORT-192.168.1.1:22" \
    -device virtio-net-pci,netdev=net0 \
    >"$CONSOLE_LOG" 2>&1 &
QEMU_PID=$!

phase BOOT 'waiting for OpenWrt SSH'
wait_for_ssh || fail 'OpenWrt SSH did not become ready'
phase BOOT 'first boot ready'
ssh_cmd "command -v ubus >/dev/null && command -v jsonfilter >/dev/null" \
    || fail 'OpenWrt does not provide ubus and jsonfilter'

phase APK 'installing package'
scp $SCP_OPTIONS "$WLOC_OPENWRT_APK" "$SSH_TARGET:/tmp/$apk_name" >/dev/null \
    || fail 'unable to copy the WLOC APK to OpenWrt'
ssh_cmd "apk add --allow-untrusted /tmp/$apk_name" >/dev/null \
    || fail 'apk could not install luci-app-wloc'
ssh_cmd "command -v rpcd >/dev/null && [ -x /etc/init.d/wloc ]" \
    || fail 'package install did not provide rpcd or the wloc init script'
phase APK 'package installed'

phase PROCD 'verifying default_postinst'
ssh_cmd /etc/init.d/wloc enabled \
    || fail 'OpenWrt default_postinst did not enable wloc'
wait_for_instance schedule \
    || fail 'OpenWrt default_postinst did not start the WLOC schedule instance'
if instance_running daemon; then
    fail 'WLOC daemon started while main.enabled was still 0'
fi
phase PROCD 'default_postinst verified'

ssh_cmd "touch /etc/config/wireless; uci set wireless.wloc_test=wifi-iface; uci set wireless.wloc_test.mode=ap; uci set wireless.wloc_test.ifname=lo; uci set wireless.wloc_test.ssid=wloc-test; uci set wloc.test=wifi; uci set wloc.test.enabled=1; uci set wloc.test.iface=lo; uci set wloc.test.latitude=0; uci set wloc.test.longitude=0; uci set wloc.test.proxy_type=direct; uci set wloc.main.enabled=1; uci commit wireless; uci commit wloc" \
    || fail 'could not create the deterministic WLOC test rule'
ssh_cmd /etc/init.d/wloc restart >/dev/null \
    || fail 'wloc could not be restarted after enabling the daemon'

instance_running daemon \
    || fail 'procd daemon instance is not running'
instance_running schedule \
    || fail 'procd schedule instance is not running'
ssh_cmd ubus call luci.wloc status >/dev/null \
    || fail 'luci.wloc status RPC failed'
phase PROCD 'instances verified'

phase FIREWALL 'applying unsaved rules'
persistent_a="$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")"
FIREWALL_B='table inet wloc_lifecycle { set apple_wloc_v4 { type ipv4_addr; flags timeout; }; }'
APPLY_COMMAND="ubus call luci.wloc firewall_apply '{\"config\":\"$FIREWALL_B\"}'"
APPLY_RESULT=/tmp/wloc-apply-result
ssh_cmd "$APPLY_COMMAND > $APPLY_RESULT" \
    || fail 'firewall Apply did not return a response'
apply_ok="$(rpc_value "cat $APPLY_RESULT" '@.ok' 2>/dev/null || true)"
case "$apply_ok" in
    true|1) ;;
    *) ssh_cmd "cat $APPLY_RESULT" >&2 || true
       fail 'firewall Apply did not return ok=true';;
esac
applied_hash="$(rpc_value "cat $APPLY_RESULT" '@.applied_hash')"
[ -n "$applied_hash" ] || fail 'firewall Apply did not return an applied revision'
ssh_cmd "rm -f $APPLY_RESULT"
ssh_cmd "nft list table inet wloc_lifecycle >/dev/null" \
    || fail 'applied firewall rules are not active'
[ "$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")" = "$persistent_a" ] \
    || fail 'Apply changed the persistent firewall file'
phase FIREWALL 'unsaved Apply active'
reboot_guest
[ "$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")" = "$persistent_a" ] \
    || fail 'reboot without Save did not restore the persistent firewall file'
if ssh_cmd "nft list table inet wloc_lifecycle >/dev/null 2>&1"; then
    fail 'unsaved firewall rules survived reboot'
fi
phase FIREWALL 'persistent rollback verified'

phase FIREWALL 'applying and saving rules'
ssh_cmd "$APPLY_COMMAND > $APPLY_RESULT" \
    || fail 'second firewall Apply did not return a response'
apply_ok="$(rpc_value "cat $APPLY_RESULT" '@.ok' 2>/dev/null || true)"
case "$apply_ok" in
    true|1) ;;
    *) ssh_cmd "cat $APPLY_RESULT" >&2 || true
       fail 'second firewall Apply did not return ok=true';;
esac
applied_hash="$(rpc_value "cat $APPLY_RESULT" '@.applied_hash')"
[ -n "$applied_hash" ] || fail 'second firewall Apply did not return an applied revision'
ssh_cmd "rm -f $APPLY_RESULT"
SAVE_COMMAND="ubus call luci.wloc firewall_save '{\"expected_applied_hash\":\"$applied_hash\"}'"
case "$(rpc_value "$SAVE_COMMAND" '@.ok')" in
    true|1) ;;
    *) fail 'firewall Save did not return ok=true';;
esac
persistent_b="$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")"
[ "$persistent_b" != "$persistent_a" ] \
    || fail 'Save did not replace the persistent firewall file'
reboot_guest
[ "$(ssh_cmd "sha256sum /etc/wloc/firewall.nft | cut -d' ' -f1")" = "$persistent_b" ] \
    || fail 'saved firewall rules did not survive reboot'
ssh_cmd "nft list table inet wloc_lifecycle >/dev/null" \
    || fail 'saved firewall table was not restored after reboot'
phase FIREWALL 'persistent Save verified'

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
if ssh_cmd "nft list set inet wloc_lifecycle apple_wloc_v4 2>/dev/null | grep -Eq 'elements[[:space:]]*=[[:space:]]*\\{[^}0-9]*[0-9]'"; then
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
ssh_cmd "nft list table inet wloc_lifecycle >/dev/null" \
    || fail 'WLOC firewall table was not active before uninstall'
ssh_cmd "test -s /var/run/wloc/firewall.applied.nft" \
    || fail 'runtime firewall snapshot was not present before uninstall'
ssh_cmd "apk del luci-app-wloc" >/dev/null \
    || fail 'apk could not uninstall luci-app-wloc'
if instance_running daemon || instance_running schedule; then
    fail 'a WLOC procd instance remained running after package uninstall'
fi
ssh_cmd "test ! -x /etc/init.d/wloc" \
    || fail 'WLOC init service remained after package uninstall'
if ssh_cmd "nft list table inet wloc_lifecycle >/dev/null 2>&1"; then
    fail 'WLOC nftables table remained after package uninstall'
fi
ssh_cmd "test ! -e /var/run/wloc/firewall.applied.nft" \
    || fail 'applied firewall snapshot remained after package uninstall'
ssh_cmd "test ! -e /var/run/wloc/firewall.applied.nft.next" \
    || fail 'staged firewall snapshot remained after package uninstall'
ssh_cmd "test ! -e /var/run/wloc/status.json && test ! -e /var/run/wloc/runtime.log && test ! -e /var/run/wloc/start-error && test ! -d /var/run/wloc/firewall.lock && test ! -e /var/run/wloc/firewall.lock/owner" \
    || fail 'WLOC runtime state remained after package uninstall'
phase UNINSTALL 'package and runtime state removed'

phase COMPLETE 'all lifecycle checks passed'
echo 'OpenWrt lifecycle tests: PASS'
