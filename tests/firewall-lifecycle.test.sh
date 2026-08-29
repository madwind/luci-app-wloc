#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/root/usr/libexec/wloc/firewall.sh"

fail() {
    echo "WLOC lifecycle tests: FAIL: $*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
runtime="$fixture_root/runtime"
mkdir -p "$runtime"
lock_helper="$ROOT/tests/native-lock.test-helper.sh"
chmod +x "$lock_helper"
firewall_source="$fixture_root/firewall.nft"
printf '%s\n' \
    'table bridge wloc {' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' \
    'table inet wloc {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '}' >"$firewall_source"

rules_helper="$fixture_root/rules-helper.sh"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\\n" "$*" >>"$WLOC_TEST_RULES_LOG"' \
    'case "${1:-}" in' \
    '  reconcile) exit "${WLOC_TEST_RECONCILE_RC:-${WLOC_TEST_RULES_RC:-0}}";;' \
    '  cleanup) exit "${WLOC_TEST_CLEANUP_RC:-${WLOC_TEST_RULES_RC:-0}}";;' \
    '  *) exit "${WLOC_TEST_RULES_RC:-0}";;' \
    'esac' >"$rules_helper"
chmod +x "$rules_helper"
rules_log="$fixture_root/rules.log"
: >"$rules_log"
export WLOC_TEST_RULES_LOG="$rules_log"
export WLOC_RULES_HELPER="$rules_helper"
export WLOC_RUNTIME_DIR="$runtime"
export WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft"
export WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next"
export WLOC_FIREWALL_PATH="$fixture_root/firewall.persistent.nft"
export WLOC_FIREWALL_LOCK="$runtime/firewall.lock"
export WLOC_FIREWALL_LOCK_COMMAND="$lock_helper"
export WLOC_STATUS_PATH="$runtime/status.json"
WLOC_FIREWALL_HELPER_SOURCE=1
. "$HELPER"

DAEMON_RUNNING=0
NFTP_CHECK_RC=0
NFTP_APPLY_RC=0
nft_state="$fixture_root/nft-state"
printf '%s\n' 'bridge:wloc' 'inet:wloc' >"$nft_state"
nft_transaction_log="$fixture_root/nft-transactions.log"
: >"$nft_transaction_log"

nft() {
    case "${1:-}" in
        --check)
            return "$NFTP_CHECK_RC"
            ;;
        --file)
            [ "$NFTP_APPLY_RC" -eq 0 ] || return "$NFTP_APPLY_RC"
            cat "$2" >>"$nft_transaction_log"
            awk '$1 == "table" && ($2 == "bridge" || $2 == "inet") && $3 == "wloc" { print $2 ":" $3 }' "$2" >"$nft_state.tmp"
            mv "$nft_state.tmp" "$nft_state"
            return 0
            ;;
        list)
            [ "${2:-}" = table ] || return 1
            grep -Fqx "${3:-}:${4:-}" "$nft_state" 2>/dev/null || return 1
            printf '%s\n' "table ${3:-} ${4:-} {"
            printf '%s\n' '}'
            ;;
        delete)
            [ "${2:-}" = table ] || return 1
            grep -Fvx "${3:-}:${4:-}" "$nft_state" >"$nft_state.tmp" || :
            mv "$nft_state.tmp" "$nft_state"
            printf '%s\n' "delete table ${3:-} ${4:-}" >>"$nft_transaction_log"
            ;;
        *)
            return 1
            ;;
    esac
}

pidof() {
    [ "$DAEMON_RUNNING" -eq 1 ]
}

uci() {
    [ "${1:-}" = -q ] && shift
    [ "${1:-}" = get ] || return 1
    [ "${2:-}" = wloc.main.listen_port ] || return 1
    printf '%s\n' 61520
}

echo '  -> Apply clears and recreates only the fixed WLOC tables'
firewall_apply_file "$firewall_source" || fail 'initial Apply failed'
grep -Fqx cleanup "$rules_log" || fail 'listener-not-ready Apply did not clear dynamic sets'
cmp -s "$firewall_source" "$WLOC_FIREWALL_RUNTIME" || fail 'Apply did not promote the runtime snapshot'
grep -Fqx 'bridge:wloc' "$nft_state" || fail 'bridge WLOC table was not active'
grep -Fqx 'inet:wloc' "$nft_state" || fail 'inet WLOC table was not active'

printf '%s\n' '{}' >"$WLOC_STATUS_PATH"
: >"$rules_log"
DAEMON_RUNNING=1
firewall_apply_file "$firewall_source" || fail 'running-daemon Apply failed'
grep -Fqx 'reconcile 61520' "$rules_log" || fail 'Apply did not reconcile the listener'
if grep -Fqx cleanup "$rules_log"; then fail 'ready listener used fail-open cleanup'; fi

echo '  -> Save persists exactly the applied snapshot'
unset FIREWALL
applied_hash="$(firewall_file_hash "$WLOC_FIREWALL_RUNTIME")"
firewall_save_snapshot "$applied_hash" || fail 'Save failed'
cmp -s "$WLOC_FIREWALL_RUNTIME" "$WLOC_FIREWALL_PATH" || fail 'Save did not copy the applied snapshot'

echo '  -> reconcile and cleanup failures keep Apply successful'
: >"$rules_log"
export WLOC_TEST_RULES_RC=1
export WLOC_TEST_CLEANUP_RC=0
firewall_apply_file "$firewall_source" || fail 'reconcile failure made Apply fail'
grep -Fqx 'reconcile 61520' "$rules_log" || fail 'reconcile was not attempted'
grep -Fqx cleanup "$rules_log" || fail 'reconcile failure did not run cleanup'
[ "$FIREWALL_RUNTIME_READY" -eq 0 ] || fail 'failed reconcile was reported ready'
[ "$FIREWALL_RUNTIME_RECOVERING" -eq 1 ] || fail 'failed reconcile did not enter recovery'
[ "$FIREWALL_RUNTIME_WARNING" = 'Runtime rule refresh failed; WLOC will retry automatically.' ] || fail 'reconcile warning was not exposed'
unset WLOC_TEST_RULES_RC WLOC_TEST_CLEANUP_RC

: >"$rules_log"
export WLOC_TEST_RECONCILE_RC=1
export WLOC_TEST_CLEANUP_RC=1
snapshot_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
firewall_apply_file "$firewall_source" || fail 'cleanup failure made Apply fail'
[ "$snapshot_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] || fail 'cleanup failure changed the applied snapshot'
[ "$FIREWALL_RUNTIME_WARNING" = 'Runtime rule refresh failed and fail-open cleanup also failed; WLOC will retry automatically.' ] || fail 'cleanup warning was not exposed'
unset WLOC_TEST_RECONCILE_RC WLOC_TEST_CLEANUP_RC

echo '  -> syntax and transaction failures preserve the previous snapshot'
snapshot_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
NFTP_CHECK_RC=1
if firewall_apply_file "$firewall_source"; then fail 'nft syntax failure was reported as success'; fi
[ "$snapshot_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] || fail 'syntax failure replaced the snapshot'
NFTP_CHECK_RC=0
NFTP_APPLY_RC=1
if firewall_apply_file "$firewall_source"; then fail 'nft transaction failure was reported as success'; fi
[ "$snapshot_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] || fail 'transaction failure replaced the snapshot'
NFTP_APPLY_RC=0

echo '  -> promotion failure removes both fixed tables and snapshots'
if ! (
    trap - EXIT
    firewall_promote_snapshot() { return 1; }
    if firewall_apply_file "$firewall_source"; then fail 'promotion failure was reported as success'; fi
    [ ! -e "$WLOC_FIREWALL_RUNTIME" ] || fail 'promotion failure retained runtime snapshot'
    [ ! -e "$WLOC_FIREWALL_RUNTIME_NEXT" ] || fail 'promotion failure retained staging snapshot'
    [ ! -s "$nft_state" ] || fail 'promotion failure retained a WLOC table'
); then
    fail 'promotion failure cleanup failed'
fi

echo '  -> remove-runtime deletes only the fixed WLOC tables and snapshots'
printf '%s\n' 'bridge:wloc' 'inet:wloc' >"$nft_state"
printf '%s\n' staged >"$WLOC_FIREWALL_RUNTIME"
printf '%s\n' staged >"$WLOC_FIREWALL_RUNTIME_NEXT"
firewall_remove_runtime || fail 'remove-runtime failed'
[ ! -s "$nft_state" ] || fail 'remove-runtime left a WLOC table'
[ ! -e "$WLOC_FIREWALL_RUNTIME" ] || fail 'remove-runtime left the applied snapshot'
[ ! -e "$WLOC_FIREWALL_RUNTIME_NEXT" ] || fail 'remove-runtime left the staging snapshot'

echo '  -> active state reports fixed table count'
printf '%s\n' 'bridge:wloc' 'inet:wloc' >"$nft_state"
firewall_active || fail 'both WLOC tables were reported inactive'
[ "$FIREWALL_ACTIVE_TABLE_COUNT" -eq 2 ] || fail 'active state was not 2/2'
grep -Fvx 'inet:wloc' "$nft_state" >"$nft_state.tmp" || :
mv "$nft_state.tmp" "$nft_state"
if firewall_active; then fail 'partial fixed table state was reported active'; fi
[ "$FIREWALL_ACTIVE_TABLE_COUNT" -eq 1 ] || fail 'partial state was not 1/2'

echo 'WLOC lifecycle tests: PASS'
