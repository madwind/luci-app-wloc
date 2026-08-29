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
printf '%s' 'table inet saved {
}' >"$persistent"
printf '%s' 'table inet applied {
}' >"$applied_source"

fake_jshn="$fixture_root/jshn.sh"
cat >"$fake_jshn" <<'EOF'
json_init() {
    response_ok=''
    response_error=''
    response_runtime_ready=''
    response_recovering=''
    response_warning=''
    response_error_code=''
    response_saved_hash=''
    response_applied_hash=''
}
json_load() { :; }
json_load_file() { :; }
json_get_var() { :; }
json_get_vars() { :; }
json_get_keys() { :; }
json_select() { :; }
json_add_object() { :; }
json_close_object() { :; }
json_add_array() { :; }
json_close_array() { :; }
json_add_boolean() {
    case "$1" in
        ok|runtime_ready|recovering) eval "response_$1=\"$2\"";;
    esac
}
json_add_int() { :; }
json_add_string() {
    case "$1" in
        error) response_error="$2";;
        error_code) response_error_code="$2";;
        saved_hash) response_saved_hash="$2";;
        applied_hash) response_applied_hash="$2";;
        warning) response_warning="$2";;
    esac
    return 0
}
json_dump() { :; }
EOF

rules_helper="$fixture_root/rules.sh"
cat >"$rules_helper" <<'EOF'
#!/bin/sh
exit "${WLOC_TEST_RULES_RC:-0}"
EOF
chmod +x "$rules_helper"

CHECK_RC=0
APPLY_RC=0
DAEMON_RUNNING=1
nft() {
    case "${1:-}" in
        --check) return "$CHECK_RC";;
        --file) return "$APPLY_RC";;
        list) return 0;;
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

echo '  -> apply updates runtime only'
printf '%s' '{}' >"$WLOC_STATUS_PATH"
export WLOC_TEST_RULES_RC=0
firewall_config="$(cat "$applied_source")"
emit_firewall_apply
cmp -s "$applied_source" "$WLOC_FIREWALL_RUNTIME" \
    || fail 'apply did not update the applied runtime snapshot'
cmp -s "$persistent" "$applied_source" \
    && fail 'apply changed the persistent firewall file'
[ "$response_ok" = 1 ] || fail 'successful apply did not return ok=true'
[ "$response_runtime_ready" = 1 ] || fail 'successful reconcile did not return runtime_ready=true'
[ "$response_recovering" = 0 ] || fail 'successful reconcile returned recovering=true'
[ -z "$response_warning" ] || fail 'successful reconcile returned a warning'

hash_b="$response_applied_hash"
[ -n "$hash_b" ] || fail 'successful Apply did not return an applied revision'

echo '  -> stale Save is rejected and the current revision can be saved'
printf '%s\n%s' 'table inet applied_c {' '}' >"$fixture_root/applied-c.nft"
firewall_config="$(cat "$fixture_root/applied-c.nft")"
export WLOC_TEST_RULES_RC=0
emit_firewall_apply
hash_c="$response_applied_hash"
[ -n "$hash_c" ] || fail 'second Apply did not return an applied revision'
[ "$hash_b" != "$hash_c" ] || fail 'different Apply operations returned the same revision'
persistent_before="$(cksum "$persistent")"
echo '  -> a busy firewall lock returns a retryable RPC error'
FIREWALL_LOCK_TIMEOUT=0
"$lock_helper" -n "$FIREWALL_LOCK" \
    || fail 'test lock helper did not acquire the busy lock'
emit_firewall_save "$hash_c"
[ "$response_ok" = 0 ] || fail 'busy Save unexpectedly succeeded'
[ "$response_error_code" = firewall_busy ] || fail 'busy Save returned the wrong error code'
[ "$persistent_before" = "$(cksum "$persistent")" ] || fail 'busy Save changed persistent storage'
[ ! -e "$FIREWALL_LOCK/owner" ] \
    || fail 'the native lock unexpectedly used an owner file'
"$lock_helper" -u "$FIREWALL_LOCK" \
    || fail 'test lock helper did not release the busy lock'
FIREWALL_LOCK_TIMEOUT=5

emit_firewall_save "$hash_b"
[ "$response_ok" = 0 ] || fail 'stale Save unexpectedly succeeded'
[ "$response_error_code" = stale_applied_revision ] || fail 'stale Save returned the wrong error code'
[ "$persistent_before" = "$(cksum "$persistent")" ] || fail 'stale Save changed persistent storage'
emit_firewall_save "$hash_c"
[ "$response_ok" = 1 ] || fail 'Save with the current revision failed'
cmp -s "$fixture_root/applied-c.nft" "$persistent" \
    || fail 'current-revision Save did not persist the applied snapshot'

echo '  -> destructive nftables commands are rejected before Apply'
runtime_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
firewall_config='flush ruleset'
emit_firewall_apply
[ "$response_ok" = 0 ] || fail 'destructive firewall command unexpectedly applied'
[ "$response_error_code" = unsupported_firewall_command ] \
    || fail 'destructive firewall command returned the wrong RPC error code'
[ "$runtime_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] \
    || fail 'destructive firewall command changed the applied snapshot'

echo '  -> reconcile failure returns a warning without failing Apply'
export WLOC_TEST_RULES_RC=1
firewall_config="$(cat "$applied_source")"
emit_firewall_apply
[ "$response_ok" = 1 ] || fail 'reconcile failure returned ok=false'
[ "$response_runtime_ready" = 0 ] || fail 'reconcile failure returned runtime_ready=true'
[ "$response_recovering" = 1 ] || fail 'reconcile failure did not return recovering=true'
[ "$response_warning" = 'Runtime rule refresh failed; WLOC will retry automatically.' ] \
    || fail 'reconcile failure returned the wrong warning'
export WLOC_TEST_RULES_RC=0

echo '  -> syntax failure keeps both snapshots'
CHECK_RC=1
firewall_config='table inet rejected { }'
emit_firewall_apply
cmp -s "$applied_source" "$WLOC_FIREWALL_RUNTIME" \
    || fail 'syntax failure replaced the applied runtime snapshot'
[ "$response_error_code" = nft_check_failed ] || fail 'syntax failure returned the wrong error code'
CHECK_RC=0

echo '  -> transaction failure keeps both snapshots'
APPLY_RC=1
firewall_config='table inet rejected { }'
emit_firewall_apply
cmp -s "$applied_source" "$WLOC_FIREWALL_RUNTIME" \
    || fail 'transaction failure replaced the applied runtime snapshot'
[ "$response_error_code" = nft_apply_failed ] || fail 'transaction failure returned the wrong error code'
APPLY_RC=0

echo '  -> snapshot promotion failure returns an explicit consistency error'
if ! (
    trap - EXIT
    firewall_promote_snapshot() { return 1; }
    firewall_config="$(cat "$applied_source")"
    emit_firewall_apply
    [ "$response_ok" = 0 ] || fail 'snapshot promotion failure returned ok=true'
    [ "$response_error" = 'Fatal consistency error: nftables rules were applied but the runtime snapshot could not be promoted.' ] \
        || fail 'snapshot promotion failure returned the wrong RPC error'
    [ "$response_error_code" = snapshot_promote_failed ] \
        || fail 'snapshot promotion failure returned the wrong error code'
    [ -s "$WLOC_FIREWALL_RUNTIME_NEXT" ] \
        || fail 'snapshot promotion failure did not retain the staged snapshot'
); then
    fail 'snapshot promotion failure RPC handling failed'
fi
rm -f "$WLOC_FIREWALL_RUNTIME_NEXT"

echo '  -> save ignores un-applied request content'
firewall_config='table inet ignored {'
current_hash="$(firewall_file_hash "$WLOC_FIREWALL_RUNTIME")"
emit_firewall_save "$current_hash"
cmp -s "$applied_source" "$persistent" \
    || fail 'save did not copy the applied snapshot to persistent storage'

echo 'WLOC RPC firewall tests: PASS'
