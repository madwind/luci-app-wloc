#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/root/usr/libexec/wloc/firewall.sh"
RULES="$ROOT/root/usr/libexec/wloc/rules.sh"

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
printf '%s\n' 'table inet wloc {' '}' >"$firewall_source"

rules_helper="$fixture_root/rules-helper.sh"
cat >"$rules_helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$WLOC_TEST_RULES_LOG"
exit "${WLOC_TEST_RULES_RC:-0}"
EOF
chmod +x "$rules_helper"
rules_log="$fixture_root/rules.log"
: >"$rules_log"
export WLOC_TEST_RULES_LOG="$rules_log"
export WLOC_RULES_HELPER="$rules_helper"
export WLOC_RUNTIME_DIR="$runtime"
export WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft"
export WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next"
export WLOC_FIREWALL_LOCK="$runtime/firewall.lock"
export WLOC_FIREWALL_LOCK_COMMAND="$lock_helper"
export WLOC_STATUS_PATH="$runtime/status.json"
WLOC_FIREWALL_HELPER_SOURCE=1
. "$HELPER"

DAEMON_RUNNING=1
NFTP_CHECK_RC=0
NFTP_APPLY_RC=0
export WLOC_TEST_RULES_RC=0
NFTP_ACTIVE_RC=0
nft_transaction_log="$fixture_root/nft-transactions.log"
: >"$nft_transaction_log"

nft() {
    case "${1:-}" in
        --check)
            return "$NFTP_CHECK_RC"
            ;;
        --file)
            if [ "$NFTP_APPLY_RC" -ne 0 ]; then
                echo 'mock nft apply failure' >&2
                return "$NFTP_APPLY_RC"
            fi
            cat "$2" >>"$nft_transaction_log"
            return 0
            ;;
        list)
            [ "${2:-}" = table ] || return 1
            return "$NFTP_ACTIVE_RC"
            ;;
        *)
            return 0
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

echo '  -> firewall apply waits for listener readiness'
: >"$rules_log"
DAEMON_RUNNING=1
NFTP_ACTIVE_RC=0
NFTP_APPLY_RC=0
rm -f "$WLOC_STATUS_PATH"
firewall_apply_file "$firewall_source" || fail 'daemon without a ready listener did not apply'
grep -Fqx cleanup "$rules_log" \
    || fail 'daemon without a ready listener did not keep dynamic sets empty'

printf '%s\n' '{}' >"$WLOC_STATUS_PATH"
: >"$rules_log"
firewall_apply_file "$firewall_source" || fail 'running daemon did not reconcile after firewall apply'
grep -Fqx 'reconcile 61520' "$rules_log" \
    || fail 'firewall apply did not immediately reconcile a running daemon'
if grep -Fqx cleanup "$rules_log"; then
    fail 'running daemon unexpectedly used cleanup instead of reconcile'
fi
    [ -s "$WLOC_FIREWALL_RUNTIME" ] || fail 'successful apply did not save the firewall snapshot'

echo '  -> reconcile failures keep Apply successful and fail open'
: >"$rules_log"
DAEMON_RUNNING=1
export WLOC_TEST_RULES_RC=1
firewall_apply_file "$firewall_source" || fail 'reconcile failure was reported as Apply failure'
grep -Fqx 'reconcile 61520' "$rules_log" \
    || fail 'reconcile was not attempted for the applied rules'
grep -Fqx cleanup "$rules_log" \
    || fail 'reconcile failure did not clean up dynamic sets'
[ "$FIREWALL_RUNTIME_STATE_SET" -eq 1 ] || fail 'successful nft Apply did not set runtime state'
[ "$FIREWALL_RUNTIME_READY" -eq 0 ] || fail 'failed reconcile was reported as runtime ready'
[ "$FIREWALL_RUNTIME_RECOVERING" -eq 1 ] || fail 'failed reconcile did not enter recovering state'
[ "$FIREWALL_RUNTIME_WARNING" = 'Runtime rule refresh failed; WLOC will retry automatically.' ] \
    || fail 'reconcile failure did not expose the recovery warning'
export WLOC_TEST_RULES_RC=0

echo '  -> stopped daemon keeps dynamic state empty'
: >"$rules_log"
DAEMON_RUNNING=0
firewall_apply_file "$firewall_source" || fail 'stopped daemon apply did not complete'
grep -Fqx cleanup "$rules_log" \
    || fail 'stopped daemon did not clear dynamic sets'
if grep -Fqx 'reconcile 61520' "$rules_log"; then
    fail 'stopped daemon was reconciled'
fi

echo '  -> snapshot staging failures do not touch nftables'
staging_parent="$fixture_root/staging-parent"
printf '%s\n' 'not a directory' >"$staging_parent"
snapshot_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
transaction_before="$(cksum "$nft_transaction_log")"
FIREWALL_RUNTIME_NEXT="$staging_parent/firewall.applied.nft.next"
if firewall_apply_file "$firewall_source" 2>/dev/null; then
    fail 'snapshot staging failure was reported as success'
fi
[ "$snapshot_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] \
    || fail 'snapshot staging failure changed the applied snapshot'
[ "$transaction_before" = "$(cksum "$nft_transaction_log")" ] \
    || fail 'snapshot staging failure changed nftables state'
FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next"

echo '  -> nft apply failures are returned'
snapshot_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
NFTP_APPLY_RC=1
if firewall_apply_file "$firewall_source"; then
    fail 'nft apply failure was reported as success'
fi
snapshot_after="$(cksum "$WLOC_FIREWALL_RUNTIME")"
[ "$snapshot_before" = "$snapshot_after" ] || fail 'failed apply replaced the last applied snapshot'
NFTP_APPLY_RC=0

echo '  -> syntax failures keep the last applied snapshot and persistent file'
saved_firewall="$fixture_root/firewall.saved.nft"
new_firewall="$fixture_root/firewall.new.nft"
printf '%s\n' 'table inet saved {' '}' >"$saved_firewall"
printf '%s\n' 'table inet new {' '}' >"$new_firewall"
cp "$saved_firewall" "$WLOC_FIREWALL_RUNTIME"
snapshot_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
NFTP_CHECK_RC=1
if firewall_apply_file "$new_firewall"; then
    fail 'nft syntax failure was reported as success'
fi
[ "$snapshot_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] \
    || fail 'syntax failure replaced the last applied snapshot'
NFTP_CHECK_RC=0
cmp -s "$saved_firewall" "$WLOC_FIREWALL_RUNTIME" \
    || fail 'syntax failure changed the persistent firewall fixture'
firewall_copy_atomic "$new_firewall" "$saved_firewall" \
    || fail 'atomic save of applied rules failed'
cmp -s "$new_firewall" "$saved_firewall" \
    || fail 'atomic save did not replace the persistent fixture'

echo '  -> snapshot promotion failures are fatal and retain staged diagnostics'
promotion_firewall="$fixture_root/firewall.promoted.nft"
printf '%s\n' 'table inet promoted {' '}' >"$promotion_firewall"
printf '%s\n' '{}' >"$WLOC_STATUS_PATH"
DAEMON_RUNNING=1
: >"$rules_log"
snapshot_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
if ! (
    trap - EXIT
    firewall_promote_snapshot() { return 1; }
    if firewall_apply_file "$promotion_firewall"; then
        fail 'snapshot promotion failure was reported as success'
    fi
    [ "$snapshot_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] \
        || fail 'snapshot promotion failure replaced the applied snapshot'
    [ -s "$FIREWALL_RUNTIME_NEXT" ] \
        || fail 'snapshot promotion failure did not retain the staged snapshot'
    grep -Fqx cleanup "$rules_log" \
        || fail 'snapshot promotion failure did not clean up dynamic sets'
); then
    fail 'snapshot promotion failure handling failed'
fi

echo '  -> active state checks the declared tables'
NFTP_ACTIVE_RC=0
firewall_active "$WLOC_FIREWALL_RUNTIME" \
    || fail 'active firewall snapshot was reported inactive'
NFTP_ACTIVE_RC=1
if firewall_active "$WLOC_FIREWALL_RUNTIME"; then
    fail 'missing active table was reported as active'
fi
NFTP_ACTIVE_RC=0

echo '  -> DNS and ingress failures propagate'
rules_runtime="$fixture_root/rules-runtime"
mkdir -p "$rules_runtime"
rules_snapshot="$rules_runtime/firewall.applied.nft"
printf '%s\n' \
    'table inet wloc {' \
    '    set apple_wloc_v4 {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '    set target_ingress_interfaces {' \
    '        type ifname' \
    '        flags timeout' \
    '    }' \
    '}' >"$rules_snapshot"
export WLOC_RUNTIME_DIR="$rules_runtime"
export WLOC_FIREWALL_RUNTIME="$rules_snapshot"
export WLOC_RULES_SOURCE=1
WLOC_AP_LIB_LOADED=1
. "$RULES"
DNS_REFRESH_SECONDS=0
DNS_RETRY_SECONDS=0
HOST_SET_LIST_RC=0
INGRESS_LIST_RC=0
NFTP_GET_RC=1
NFTP_ADD_RC=0
NFTP_BATCH_RC=0
AP_LOOKUP_RC=0
DNS_MODE=fail
HOST_SET_DUMP='type ipv4_addr
flags timeout
elements = { 1.2.3.4 expires 10s }'
INGRESS_SET_DUMP='type ifname
flags timeout'
rules_batch_log="$fixture_root/rules-batches.log"
: >"$rules_batch_log"

nft() {
    if [ "${1:-}" = list ] && [ "${2:-}" = set ]; then
        case "${5:-}" in
            apple_wloc_v4)
                printf '%s\n' "$HOST_SET_DUMP"
                return "$HOST_SET_LIST_RC"
                ;;
            target_ingress_interfaces)
                printf '%s\n' "$INGRESS_SET_DUMP"
                return "$INGRESS_LIST_RC"
                ;;
            *)
                return 1
                ;;
        esac
    fi
    if [ "${1:-}" = get ]; then
        return "$NFTP_GET_RC"
    fi
    if [ "${1:-}" = add ]; then
        return "$NFTP_ADD_RC"
    fi
    if [ "${1:-}" = -f ] && [ "${2:-}" = - ]; then
        cat >>"$rules_batch_log"
        return "$NFTP_BATCH_RC"
    fi
    if [ "${1:-}" = flush ]; then
        return 0
    fi
    return 1
}

nslookup() {
    if [ "$DNS_MODE" = fail ]; then
        return 0
    fi
    printf '%s\n' 'Name: gs-loc.apple.com' 'Address: 1.2.3.4'
}

config_load() {
    return 0
}

config_foreach() {
    "$1" wifi_us
}

config_get() {
    local destination="$1" section="$2" option="$3" value="${4:-}"
    case "$option" in
        enabled) value=1;;
        iface) value=phy0-ap0;;
    esac
    eval "$destination=\$value"
}

config_get_bool() {
    config_get "$@"
}

wloc_ap_find_section_by_ifname() {
    return "$AP_LOOKUP_RC"
}

reset_dns_attempt() {
    rm -f "$STAMP" "$DNS_ATTEMPT_STAMP"
}

reset_dns_attempt
resolve_hosts || fail 'an existing host address was not preserved during a DNS outage'

HOST_SET_DUMP='type ipv4_addr
flags timeout
elements = { }'
reset_dns_attempt
if resolve_hosts; then
    fail 'empty host set was treated as healthy after DNS failure'
fi

DNS_MODE=ok
NFTP_ADD_RC=1
reset_dns_attempt
if resolve_hosts; then
    fail 'nft add failure was treated as healthy'
fi

NFTP_ADD_RC=0
reset_dns_attempt
resolve_hosts || fail 'DNS recovery did not succeed on the next reconcile'

NFTP_BATCH_RC=1
if sync_ingress_interfaces; then
    fail 'ingress nft failure was treated as healthy'
fi

AP_LOOKUP_RC=1
NFTP_BATCH_RC=0
reset_dns_attempt
if reconcile 61520; then
    fail 'AP interface resolution failure was treated as healthy'
fi

echo 'WLOC lifecycle tests: PASS'
