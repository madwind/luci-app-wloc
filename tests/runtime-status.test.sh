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
    [ "${1:-}" = list ] && [ "${2:-}" = table ] || return 1
    case "${3:-}:${4:-}" in
        bridge:wloc)
            printf '%s\n' \
                'table bridge wloc {' \
                '    counter packets 99 bytes 100 comment "wloc owned ingress redirect"' \
                '}'
            ;;
        inet:wloc)
            printf '%s\n' \
                'table inet wloc {' \
                '    counter packets 3 bytes 100 comment "wloc owned ingress redirect"' \
                '    counter packets 77 bytes 100 comment "wloc owned other redirect"' \
                '}'
            ;;
        *) return 1;;
    esac
}

echo '  -> fixed bridge and inet table status is reported'
printf '%s\n' 'table bridge wloc { }' 'table inet wloc { }' >"$runtime"
printf '%s\n' 'table inet persistent { }' >"$persistent"
firewall_status_values
[ "$rules_present" = 1 ] || fail 'runtime snapshot was not marked present'
[ "$firewall_is_active" = 1 ] || fail 'both WLOC tables were not reported active'
[ "$FIREWALL_ACTIVE_TABLE_COUNT" = 2 ] || fail 'fixed table count was not reported as 2/2'
[ "$attempts" = 3 ] || fail 'inet WLOC redirect counter was not reported'
[ "$intercepted" = 3 ] || fail 'bridge or non-matching counters leaked into status'

echo '  -> a missing fixed table reports partial active state'
nft() {
    [ "${1:-}" = list ] && [ "${2:-}" = table ] || return 1
    [ "${3:-}:${4:-}" = 'inet:wloc' ] && printf '%s\n' \
        'table inet wloc {' \
        '    counter packets 4 bytes 100 comment "wloc owned ingress redirect"' \
        '}'
}
firewall_status_values
[ "$firewall_is_active" = 0 ] || fail 'partial fixed table state was reported fully active'
[ "$FIREWALL_ACTIVE_TABLE_COUNT" = 1 ] || fail 'partial fixed table count was not reported as 1/2'
[ "$attempts" = 4 ] || fail 'inet WLOC counter was not read from the fixed table'

echo '  -> persistent content does not provide generic table fallback'
rm -f "$runtime"
printf '%s\n' 'table bridge custom { }' 'table inet custom { }' >"$persistent"
nft() { return 1; }
firewall_status_values
[ "$rules_present" = 1 ] || fail 'persistent rules were not marked present'
[ "$FIREWALL_ACTIVE_TABLE_COUNT" = 0 ] || fail 'custom persistent tables were discovered as WLOC tables'
[ "$attempts" = 0 ] || fail 'custom persistent counters were aggregated'

echo 'WLOC runtime status tests: PASS'
