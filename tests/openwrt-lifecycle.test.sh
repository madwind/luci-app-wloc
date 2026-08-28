#!/bin/sh
set -eu

fail() {
	echo "OpenWrt lifecycle tests: FAIL: $*" >&2
	exit 1
}

if [ -z "${WLOC_OPENWRT_IMAGE:-}" ] || [ -z "${WLOC_OPENWRT_APK:-}" ] || [ -z "${WLOC_OPENWRT_SSH_KEY:-}" ]; then
	echo 'OpenWrt lifecycle tests: SKIP (set WLOC_OPENWRT_IMAGE, WLOC_OPENWRT_APK, and WLOC_OPENWRT_SSH_KEY)'
	exit 0
fi

for command in basename grep qemu-system-x86_64 scp ssh; do
	command -v "$command" >/dev/null 2>&1 \
		|| fail "required command not found: $command"
done
[ -f "$WLOC_OPENWRT_IMAGE" ] || fail "OpenWrt image not found: $WLOC_OPENWRT_IMAGE"
[ -f "$WLOC_OPENWRT_APK" ] || fail "WLOC APK not found: $WLOC_OPENWRT_APK"
[ -f "$WLOC_OPENWRT_SSH_KEY" ] || fail "SSH key not found: $WLOC_OPENWRT_SSH_KEY"

SSH_PORT=${WLOC_OPENWRT_SSH_PORT:-22022}
MEMORY=${WLOC_OPENWRT_MEMORY:-256M}
SSH_TARGET="root@127.0.0.1"
SSH_OPTIONS="-i $WLOC_OPENWRT_SSH_KEY -p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
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

apk_name="$(basename "$WLOC_OPENWRT_APK")"
qemu-system-x86_64 \
	-machine q35 \
	-m "$MEMORY" \
	-nographic \
	-snapshot \
	-drive "file=$WLOC_OPENWRT_IMAGE,format=raw,if=virtio" \
	-netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" \
	-device virtio-net-pci,netdev=net0 \
	>"$CONSOLE_LOG" 2>&1 &
QEMU_PID=$!

echo '  -> wait for OpenWrt SSH'
ready=0
for attempt in $(seq 1 60); do
	if ssh_cmd true >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 2
done
[ "$ready" -eq 1 ] || fail 'OpenWrt SSH did not become ready'

echo '  -> install package and create a deterministic test rule'
scp $SSH_OPTIONS "$WLOC_OPENWRT_APK" "$SSH_TARGET:/tmp/$apk_name" >/dev/null \
	|| fail 'unable to copy the WLOC APK to OpenWrt'
ssh_cmd "apk add --allow-untrusted /tmp/$apk_name" >/dev/null \
	|| fail 'apk could not install luci-app-wloc'
ssh_cmd "uci set wireless.wloc_test=wifi-iface; uci set wireless.wloc_test.mode=ap; uci set wireless.wloc_test.ifname=lo; uci set wireless.wloc_test.ssid=wloc-test; uci set wloc.test=wifi; uci set wloc.test.enabled=1; uci set wloc.test.iface=lo; uci set wloc.test.latitude=0; uci set wloc.test.longitude=0; uci set wloc.test.proxy_type=direct; uci commit wireless; uci commit wloc" \
	|| fail 'could not create the deterministic WLOC test rule'
ssh_cmd /etc/init.d/wloc enable >/dev/null \
	|| fail 'wloc could not be enabled'
ssh_cmd /etc/init.d/wloc start >/dev/null \
	|| fail 'wloc could not be started'

service_json="$(ssh_cmd "ubus call service list '{\"name\":\"wloc\"}'")" \
	|| fail 'ubus service list did not return'
printf '%s\n' "$service_json" \
	| grep -Eq '"daemon"[[:space:]]*:[[:space:]]*\{[^}]*"running"[[:space:]]*:[[:space:]]*true' \
	|| fail 'procd daemon instance is not running'
ssh_cmd ubus call luci.wloc status >/dev/null \
	|| fail 'luci.wloc status RPC failed'

daemon_pid="$(ssh_cmd "jsonfilter -e '@.wloc.instances.daemon.pid'" 2>/dev/null || true)"
case "$daemon_pid" in
	*[!0-9]*|'') fail 'could not find the procd-managed wlocd PID';;
esac

echo '  -> procd crash recovery'
ssh_cmd "kill -9 $daemon_pid" >/dev/null \
	|| fail 'could not terminate the procd-managed daemon'
recovered=0
for attempt in $(seq 1 30); do
	new_pid="$(ssh_cmd "jsonfilter -e '@.wloc.instances.daemon.pid'" 2>/dev/null || true)"
	if [ "$new_pid" != "$daemon_pid" ] && printf '%s' "$new_pid" | grep -Eq '^[0-9]+$'; then
		recovered=1
		break
	fi
	sleep 1
done
[ "$recovered" -eq 1 ] || fail 'procd did not respawn wlocd'
ssh_cmd logread -e wlocd | grep -q 'wlocd:' \
	|| fail 'wlocd stderr was not visible in logread'

echo '  -> service reload and stop'
ssh_cmd "uci set wloc.main.debug=1; uci commit wloc; ubus call service event '{\"type\":\"config.change\",\"data\":{\"package\":\"wloc\"}}'" \
	|| fail 'service config reload failed'
ssh_cmd /etc/init.d/wloc stop >/dev/null \
	|| fail 'wloc could not be stopped'
service_json="$(ssh_cmd "ubus call service list '{\"name\":\"wloc\"}'")" \
	|| fail 'ubus service list failed after stop'
if printf '%s\n' "$service_json" \
	| grep -Eq '"(daemon|schedule)"[[:space:]]*:[[:space:]]*\{[^}]*"running"[[:space:]]*:[[:space:]]*true'; then
	fail 'a WLOC procd instance remained running after stop'
fi

echo 'OpenWrt lifecycle tests: PASS'
