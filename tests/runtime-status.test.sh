#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RPC="$ROOT/root/usr/libexec/rpcd/luci.wloc"

fail() {
    echo "WLOC runtime status tests: FAIL: $*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
runtime="$fixture_root/firewall.applied.nft"
persistent="$fixture_root/firewall.nft"
helper="$ROOT/root/usr/libexec/wloc/firewall.sh"
jshn="$fixture_root/jshn.sh"
printf '%s\n' 'json_init() { :; }' >"$jshn"

export WLOC_RPC_SOURCE=1
export WLOC_JSHN_PATH="$jshn"
export WLOC_FIREWALL_HELPER_PATH="$helper"
export WLOC_FIREWALL_RUNTIME="$runtime"
export WLOC_FIREWALL_PATH="$persistent"
export WLOC_RUNTIME_DIR="$fixture_root"
export WLOC_STATUS_PATH="$fixture_root/status.json"
. "$RPC"

nft() {
    [ "$1" = list ] && [ "$2" = table ] || return 1
    case "$3:$4" in
        inet:wloc)
            printf '%s\n' \
                'table inet wloc {' \
                '    counter packets 3 bytes 100 comment "wloc owned AP redirect"' \
                '}'
            ;;
        bridge:custom_bridge)
            printf '%s\n' \
                'table bridge custom_bridge {' \
                '    counter packets 2 bytes 100 comment "wloc owned ingress redirect"' \
                '}'
            ;;
        inet:custom_inet)
            printf '%s\n' \
                'table inet custom_inet {' \
                '    counter packets 4 bytes 100 comment "wloc owned AP redirect"' \
                '}'
            ;;
        bridge:fallback_wloc)
            printf '%s\n' \
                'table bridge fallback_wloc {' \
                '    counter packets 6 bytes 100 comment "wloc owned ingress redirect"' \
                '}'
            ;;
        *) return 1;;
    esac
}

echo '  -> standard inet table counters are reported'
printf '%s\n' 'table inet wloc { }' >"$runtime"
printf '%s\n' 'table inet persistent { }' >"$persistent"
firewall_status_values
[ "$rules_present" = 1 ] || fail 'applied snapshot was not marked present'
[ "$firewall_is_active" = 1 ] || fail 'active inet table was reported inactive'
[ "$attempts" = 3 ] || fail 'inet table attempt counter was not reported'
[ "$intercepted" = 3 ] || fail 'inet table redirect counter was not reported'

echo '  -> all custom tables are scanned and a failed table is skipped'
printf '%s\n' \
    'table bridge custom_bridge { }' \
    'table inet custom_inet { }' \
    'table inet missing { }' >"$runtime"
firewall_status_values
[ "$attempts" = 6 ] || fail 'custom table counters were not accumulated'
[ "$intercepted" = 6 ] || fail 'custom table redirect counters were not accumulated'
[ "$firewall_is_active" = 0 ] || fail 'a missing table was reported as fully active'

echo '  -> missing tables produce zero counters'
printf '%s\n' 'table inet missing { }' >"$runtime"
firewall_status_values
[ "$attempts" = 0 ] || fail 'missing table produced a non-zero attempt counter'
[ "$intercepted" = 0 ] || fail 'missing table produced a non-zero redirect counter'

echo '  -> persistent rules are used when no applied snapshot exists'
rm -f "$runtime"
printf '%s\n' 'table bridge fallback_wloc { }' >"$persistent"
firewall_status_values
[ "$rules_present" = 1 ] || fail 'persistent fallback was not marked present'
[ "$attempts" = 6 ] || fail 'persistent fallback counters were not reported'
[ "$intercepted" = 6 ] || fail 'persistent fallback redirect counter was not reported'

echo 'WLOC runtime status tests: PASS'
