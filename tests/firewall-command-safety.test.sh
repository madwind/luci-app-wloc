#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/root/usr/libexec/wloc/firewall.sh"
LOCK_HELPER="$ROOT/tests/native-lock.test-helper.sh"

fail() {
    echo "WLOC firewall command safety tests: FAIL: $*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
runtime="$fixture_root/runtime"
mkdir -p "$runtime"
chmod +x "$LOCK_HELPER"

rules_helper="$fixture_root/rules.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$rules_helper"
chmod +x "$rules_helper"

valid="$fixture_root/valid.nft"
printf '%s\n' \
    '# WLOC owns these two table definitions.' \
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
    '}' >"$valid"

export WLOC_RUNTIME_DIR="$runtime"
export WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft"
export WLOC_FIREWALL_RUNTIME_NEXT="$runtime/firewall.applied.nft.next"
export WLOC_FIREWALL_LOCK="$runtime/firewall.lock"
export WLOC_FIREWALL_LOCK_COMMAND="$LOCK_HELPER"
export WLOC_RULES_HELPER="$rules_helper"
WLOC_FIREWALL_HELPER_SOURCE=1
. "$HELPER"

CHECK_LOG="$fixture_root/check.log"
APPLY_LOG="$fixture_root/apply.log"
: >"$CHECK_LOG"
: >"$APPLY_LOG"
CHECK_RC=0
APPLY_RC=0

nft() {
    case "${1:-}" in
        --check)
            cat "$3" >>"$CHECK_LOG"
            return "$CHECK_RC"
            ;;
        --file)
            cat "$2" >>"$APPLY_LOG"
            return "$APPLY_RC"
            ;;
        list)
            [ "${2:-}" = table ] || return 1
            [ "${3:-}:${4:-}" = 'bridge:wloc' ] || \
                [ "${3:-}:${4:-}" = 'inet:wloc' ]
            ;;
        *)
            return 1
            ;;
    esac
}

pidof() {
    return 1
}

echo '  -> fixed bridge and inet WLOC tables pass ownership and Apply'
firewall_validate_file "$valid" \
    || fail 'valid fixed WLOC table definitions were rejected'
firewall_apply_file "$valid" \
    || fail 'valid fixed WLOC table definitions could not be applied'
cmp -s "$valid" "$WLOC_FIREWALL_RUNTIME" \
    || fail 'the valid applied snapshot was not promoted'
grep -Fqx 'delete table bridge wloc' "$CHECK_LOG" \
    || fail 'bridge WLOC replacement was not checked by nft'
grep -Fqx 'delete table inet wloc' "$CHECK_LOG" \
    || fail 'inet WLOC replacement was not checked by nft'
[ -s "$APPLY_LOG" ] || fail 'valid rules were not passed to the nft transaction'

runtime_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
check_before="$(cksum "$CHECK_LOG")"
apply_before="$(cksum "$APPLY_LOG")"
for header in \
    'table inet custom {' \
    'table bridge foo {' \
    'table ip wloc {' \
    'table ip6 wloc {' \
    'table inet wloc2 {' \
    'table netdev wloc {' \
    'add table inet wloc'; do
    source="$fixture_root/ownership-$RANDOM.nft"
    printf '%s\n' "$header" '}' >"$source"
    echo "  -> reject non-owned table declaration: $header"
    if firewall_validate_file "$source"; then
        fail "non-owned table passed ownership validation: $header"
    fi
    [ "${firewall_error_code:-}" = unsupported_firewall_command ] \
        || fail "non-owned table returned the wrong error: $header"
    [ "$check_before" = "$(cksum "$CHECK_LOG")" ] \
        || fail "non-owned table reached nft --check: $header"
    if firewall_apply_file "$source"; then
        fail "non-owned table was applied: $header"
    fi
    [ "$apply_before" = "$(cksum "$APPLY_LOG")" ] \
        || fail "non-owned table reached the nft transaction: $header"
    [ "$runtime_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] \
        || fail "non-owned table changed the applied snapshot: $header"
    [ ! -e "$WLOC_FIREWALL_RUNTIME_NEXT" ] \
        || fail "non-owned table left a staged snapshot: $header"
done

for command in \
    'flush ruleset' \
    'include "/etc/nftables.d/*.nft"' \
    'delete table inet wloc' \
    'destroy table inet wloc' \
    'reset rules' \
    'insert rule inet wloc input accept' \
    'replace rule inet wloc input handle 1 accept'; do
    source="$fixture_root/command-$RANDOM.nft"
    printf '%s\n' "$command" >"$source"
    echo "  -> reject command form: $command"
    if firewall_validate_file "$source"; then
        fail "unsupported command passed validation: $command"
    fi
    [ "${firewall_error_code:-}" = unsupported_firewall_command ] \
        || fail "unsupported command returned the wrong error: $command"
    [ "$check_before" = "$(cksum "$CHECK_LOG")" ] \
        || fail "unsupported command reached nft --check: $command"
done

echo '  -> nft validates syntax after ownership passes'
invalid="$fixture_root/invalid.nft"
printf '%s\n' 'table inet wloc {' '    this is invalid nft syntax' '}' >"$invalid"
CHECK_RC=1
if firewall_validate_file "$invalid"; then
    fail 'invalid nft syntax passed validation'
fi
[ "${firewall_error_code:-}" = nft_check_failed ] \
    || fail 'invalid nft syntax returned the wrong error'
CHECK_RC=0

echo 'WLOC firewall command safety tests: PASS'
