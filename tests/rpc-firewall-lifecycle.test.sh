#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RPC="$ROOT/root/usr/libexec/rpcd/luci.wloc"
HELPER="$ROOT/root/usr/libexec/wloc/firewall.sh"

fail() {
    echo "WLOC RPC firewall tests: FAIL: $*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
runtime="$fixture_root/runtime"
mkdir -p "$runtime"
lock_helper="$ROOT/tests/native-lock.test-helper.sh"
chmod +x "$lock_helper"
persistent="$fixture_root/firewall.saved.nft"
applied_source="$fixture_root/firewall.applied-input.nft"
printf '%s' 'table bridge wloc {
}
table inet wloc {
}' >"$persistent"
cp "$persistent" "$applied_source"

fake_jshn="$fixture_root/jshn.sh"
printf '%s\n' \
    'json_init() {' \
    '  response_ok=' \
    '  response_error=' \
    '  response_runtime_ready=' \
    '  response_recovering=' \
    '  response_warning=' \
    '  response_error_code=' \
    '  response_saved_hash=' \
    '  response_applied_hash=' \
    '  response_bridge_active=' \
    '  response_inet_active=' \
    '}' \
    'json_load() { :; }' \
    'json_load_file() { :; }' \
    'json_get_var() { :; }' \
    'json_get_vars() { :; }' \
    'json_get_keys() { :; }' \
    'json_select() { :; }' \
    'json_add_object() { :; }' \
    'json_close_object() { :; }' \
    'json_add_array() { :; }' \
    'json_close_array() { :; }' \
    'json_add_boolean() {' \
    '  case "$1" in' \
    '    ok|runtime_ready|recovering|bridge_active|inet_active) eval "response_$1=\"$2\"";;' \
    '  esac' \
    '}' \
    'json_add_int() { :; }' \
    'json_add_string() {' \
    '  case "$1" in' \
    '    error) response_error="$2";;' \
    '    error_code) response_error_code="$2";;' \
    '    saved_hash) response_saved_hash="$2";;' \
    '    applied_hash) response_applied_hash="$2";;' \
    '    warning) response_warning="$2";;' \
    '  esac' \
    '}' \
    'json_dump() { :; }' >"$fake_jshn"

rules_helper="$fixture_root/rules.sh"
printf '%s\n' \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '  reconcile) exit "${WLOC_TEST_RECONCILE_RC:-${WLOC_TEST_RULES_RC:-0}}";;' \
    '  cleanup) exit "${WLOC_TEST_CLEANUP_RC:-${WLOC_TEST_RULES_RC:-0}}";;' \
    '  *) exit "${WLOC_TEST_RULES_RC:-0}";;' \
    'esac' >"$rules_helper"
chmod +x "$rules_helper"

CHECK_RC=0
APPLY_RC=0
DAEMON_RUNNING=1
nft() {
    case "${1:-}" in
        --check) return "$CHECK_RC";;
        --file) return "$APPLY_RC";;
        list) return 0;;
        delete) return 0;;
        *) return 0;;
    esac
}
pidof() { [ "$DAEMON_RUNNING" -eq 1 ]; }
uci() {
    [ "${1:-}" = -q ] && shift
    [ "${1:-}" = get ] && [ "${2:-}" = wloc.main.listen_port ] || return 1
    printf '%s\n' 61520
}

export WLOC_RPC_SOURCE=1
export WLOC_JSHN_PATH="$fake_jshn"
export WLOC_FIREWALL_HELPER_PATH="$HELPER"
export WLOC_RULES_HELPER="$rules_helper"
export WLOC_RUNTIME_DIR="$runtime"
export WLOC_FIREWALL_PATH="$persistent"
export WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft"
export WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next"
export WLOC_FIREWALL_LOCK="$runtime/firewall.lock"
export WLOC_FIREWALL_LOCK_COMMAND="$lock_helper"
export WLOC_STATUS_PATH="$runtime/status.json"
. "$RPC"

echo '  -> Apply updates runtime only and returns both fixed table states'
printf '%s' '{}' >"$WLOC_STATUS_PATH"
firewall_config="$(cat "$applied_source")"
emit_firewall_apply
cmp -s "$applied_source" "$WLOC_FIREWALL_RUNTIME" || fail 'Apply did not update runtime'
cmp -s "$persistent" "$applied_source" || fail 'Apply changed persistent storage'
[ "$response_ok" = 1 ] || fail 'Apply did not return ok=true'
[ "$response_runtime_ready" = 1 ] || fail 'Apply was not runtime-ready'
[ "$response_bridge_active" = 1 ] || fail 'bridge state was not returned'
[ "$response_inet_active" = 1 ] || fail 'inet state was not returned'
hash_b="$response_applied_hash"

echo '  -> current applied revision is required for Save'
firewall_config='table bridge wloc {
}
table inet wloc {
    chain changed { }
}'
emit_firewall_apply
hash_c="$response_applied_hash"
[ -n "$hash_b" ] && [ -n "$hash_c" ] && [ "$hash_b" != "$hash_c" ] || fail 'second Apply did not create a revision'
persistent_before="$(cksum "$persistent")"
FIREWALL_LOCK_TIMEOUT=0
"$lock_helper" -n "$FIREWALL_LOCK" || fail 'test lock helper did not acquire busy lock'
emit_firewall_save "$hash_c"
[ "$response_error_code" = firewall_busy ] || fail 'busy Save returned the wrong error'
[ "$persistent_before" = "$(cksum "$persistent")" ] || fail 'busy Save changed storage'
"$lock_helper" -u "$FIREWALL_LOCK"
FIREWALL_LOCK_TIMEOUT=5
emit_firewall_save "$hash_b"
[ "$response_error_code" = stale_applied_revision ] || fail 'stale Save returned the wrong error'
emit_firewall_save "$hash_c"
[ "$response_ok" = 1 ] || fail 'current Save failed'
cmp -s "$fixture_root/applied-c.nft" "$persistent" 2>/dev/null || cmp -s "$WLOC_FIREWALL_RUNTIME" "$persistent" || fail 'Save did not persist applied rules'

echo '  -> ownership and command checks reject unsafe requests'
runtime_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
for firewall_config in 'table inet custom { }' 'table ip wloc { }' 'table inet wloc2 { }' 'flush ruleset' 'include "/etc/nftables.d/*.nft"'; do
    emit_firewall_apply
    [ "$response_ok" = 0 ] || fail "unsafe request was accepted: $firewall_config"
    [ "$response_error_code" = unsupported_firewall_command ] || fail 'unsafe request returned the wrong error'
    [ "$runtime_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] || fail 'unsafe request changed runtime'
done

echo '  -> reconcile, syntax, and transaction failures are reported'
export WLOC_TEST_RULES_RC=1
export WLOC_TEST_CLEANUP_RC=0
firewall_config="$(cat "$applied_source")"
emit_firewall_apply
[ "$response_ok" = 1 ] && [ "$response_recovering" = 1 ] || fail 'reconcile failure was not fail-open'
[ "$response_warning" = 'Runtime rule refresh failed; WLOC will retry automatically.' ] || fail 'wrong reconcile warning'
unset WLOC_TEST_RULES_RC WLOC_TEST_CLEANUP_RC
CHECK_RC=1
emit_firewall_apply
[ "$response_error_code" = nft_check_failed ] || fail 'syntax failure returned the wrong error'
CHECK_RC=0
APPLY_RC=1
emit_firewall_apply
[ "$response_error_code" = nft_apply_failed ] || fail 'transaction failure returned the wrong error'
APPLY_RC=0

echo '  -> promotion failure removes the staged snapshot'
if ! (
    trap - EXIT
    firewall_promote_snapshot() { return 1; }
    firewall_config="$(cat "$applied_source")"
    emit_firewall_apply
    [ "$response_error_code" = snapshot_promote_failed ] || fail 'promotion failure returned the wrong error'
    [ ! -e "$WLOC_FIREWALL_RUNTIME" ] || fail 'promotion failure retained runtime'
    [ ! -e "$WLOC_FIREWALL_RUNTIME_NEXT" ] || fail 'promotion failure retained staging'
); then
    fail 'promotion failure handling failed'
fi

echo 'WLOC RPC firewall tests: PASS'
