#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/root/usr/libexec/wloc/firewall.sh"

fail() {
    echo "WLOC firewall concurrency tests: FAIL: $*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
runtime="$fixture_root/runtime"
mkdir -p "$runtime"
source_a="$fixture_root/firewall-a.nft"
source_b="$fixture_root/firewall-b.nft"
printf '%s\n' 'table inet apply_a {' '}' >"$source_a"
printf '%s\n' 'table inet apply_b {' '}' >"$source_b"
printf '%s\n' 'table inet old {' '}' >"$runtime/firewall.applied.nft"

WLOC_RUNTIME_DIR="$runtime"
WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft"
WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next"
WLOC_FIREWALL_HELPER_SOURCE=1
. "$HELPER"

echo '  -> busy locks fail fast and stale locks are recoverable'
FIREWALL_LOCK_TIMEOUT=0
mkdir "$FIREWALL_LOCK"
printf '%s\n' "$$ unknown" >"$FIREWALL_LOCK/owner"
if firewall_lock_acquire; then
    fail 'an active firewall lock was acquired by a second operation'
fi
[ "${firewall_error_code:-}" = firewall_busy ] \
    || fail 'an active firewall lock did not return firewall_busy'
rm -f "$FIREWALL_LOCK/owner"
rmdir "$FIREWALL_LOCK"

mkdir "$FIREWALL_LOCK"
printf '%s\n' '2147483647 unknown' >"$FIREWALL_LOCK/owner"
firewall_lock_acquire || fail 'a stale firewall lock was not recovered'
firewall_lock_release
[ ! -e "$FIREWALL_LOCK" ] || fail 'the recovered firewall lock was not released'

rules_helper="$fixture_root/rules.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$rules_helper"
chmod +x "$rules_helper"

worker="$fixture_root/worker.sh"
cat >"$worker" <<'EOF'
#!/bin/sh
set -eu

nft() {
    case "${1:-}" in
        list)
            [ "${2:-}" = table ] || return 1
            grep -Fqx "${3}:${4}" "$WLOC_TEST_NFT_STATE" 2>/dev/null
            ;;
        --check)
            return 0
            ;;
        --file)
            transaction="$2"
            printf '%s\n' "$WLOC_TEST_ACTOR" >>"$WLOC_TEST_NFT_LOG"
            table="$(awk '$1 == "table" && $2 ~ /^(ip|ip6|inet|arp|bridge|netdev)$/ { print $2 ":" $3; exit }' "$transaction")"
            printf '%s\n' "$table" >"$WLOC_TEST_NFT_STATE"
            if [ "$WLOC_TEST_ACTOR" = A ]; then
                : >"$WLOC_TEST_APPLY_MARKER"
                while [ ! -e "$WLOC_TEST_APPLY_RELEASE" ]; do
                    sleep 1
                done
            fi
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

pidof() {
    return 1
}

WLOC_FIREWALL_HELPER_SOURCE=1
. "$WLOC_TEST_HELPER"
firewall_apply_file "$WLOC_TEST_SOURCE"
EOF
chmod +x "$worker"

state="$fixture_root/nft-state"
log="$fixture_root/nft.log"
marker="$fixture_root/apply-a-entered"
release="$fixture_root/apply-a-release"
printf '%s\n' 'inet:old' >"$state"
: >"$log"

echo '  -> concurrent Apply operations serialize the complete state transition'
WLOC_TEST_HELPER="$HELPER" \
WLOC_TEST_SOURCE="$source_a" \
WLOC_TEST_ACTOR=A \
WLOC_TEST_NFT_STATE="$state" \
WLOC_TEST_NFT_LOG="$log" \
WLOC_TEST_APPLY_MARKER="$marker" \
WLOC_TEST_APPLY_RELEASE="$release" \
WLOC_RUNTIME_DIR="$runtime" \
WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft" \
WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next" \
WLOC_FIREWALL_LOCK_TIMEOUT=20 \
WLOC_RULES_HELPER="$rules_helper" \
"$worker" &
apply_a_pid=$!

attempt=0
while [ ! -e "$marker" ] && [ "$attempt" -lt 20 ]; do
    sleep 1
    attempt=$((attempt + 1))
done
[ -e "$marker" ] || fail 'Apply A did not enter the critical section'
cmp -s "$source_a" "$runtime/firewall.applied.nft.next" \
    || fail 'Apply A did not own the staged snapshot'
[ -s "$runtime/firewall.applied.nft" ] \
    || fail 'the initial applied snapshot disappeared'

WLOC_TEST_HELPER="$HELPER" \
WLOC_TEST_SOURCE="$source_b" \
WLOC_TEST_ACTOR=B \
WLOC_TEST_NFT_STATE="$state" \
WLOC_TEST_NFT_LOG="$log" \
WLOC_TEST_APPLY_MARKER="$fixture_root/apply-b-entered" \
WLOC_TEST_APPLY_RELEASE="$fixture_root/apply-b-release" \
WLOC_RUNTIME_DIR="$runtime" \
WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft" \
WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next" \
WLOC_FIREWALL_LOCK_TIMEOUT=20 \
WLOC_RULES_HELPER="$rules_helper" \
"$worker" &
apply_b_pid=$!

sleep 1
cmp -s "$source_a" "$runtime/firewall.applied.nft.next" \
    || fail 'Apply B mutated the staged snapshot before Apply A completed'
if cmp -s "$source_b" "$runtime/firewall.applied.nft.next"; then
    fail 'Apply B overwrote the staged snapshot while Apply A was active'
fi

: >"$release"
wait "$apply_a_pid" || fail 'serialized Apply A failed'
wait "$apply_b_pid" || fail 'serialized Apply B failed'

cmp -s "$source_b" "$runtime/firewall.applied.nft" \
    || fail 'the applied snapshot does not contain the last serialized Apply'
grep -Fqx 'inet:apply_b' "$state" \
    || fail 'the kernel model does not contain the last serialized Apply'
[ "$(sed -n '1p' "$log")" = A ] || fail 'Apply A was not the first transaction'
[ "$(sed -n '2p' "$log")" = B ] || fail 'Apply B did not start after Apply A'
[ ! -e "$runtime/firewall.lock" ] || fail 'firewall lock remained after both transactions'

echo 'WLOC firewall concurrency tests: PASS'
