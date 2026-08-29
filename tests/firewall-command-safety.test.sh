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
    '# WLOC table definitions may contain normal table members.' \
    'table inet wloc_test {' \
    '    set clients {' \
    '        type ipv4_addr' \
    '        flags timeout' \
    '    }' \
    '    chain test {' \
    '        type filter hook prerouting priority -1;' \
    '        policy accept;' \
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

nft() {
    case "${1:-}" in
        --check)
            cat "$3" >>"$CHECK_LOG"
            return 0
            ;;
        --file)
            cat "$2" >>"$APPLY_LOG"
            return 0
            ;;
        list)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

pidof() {
    return 1
}

echo '  -> declarative table definitions pass validation and Apply'
firewall_validate_file "$valid" \
    || fail 'a valid declarative table definition was rejected'
firewall_apply_file "$valid" \
    || fail 'a valid declarative table definition could not be applied'
cmp -s "$valid" "$WLOC_FIREWALL_RUNTIME" \
    || fail 'the valid applied snapshot was not promoted'
[ -s "$CHECK_LOG" ] || fail 'valid rules were not passed to nft --check'
[ -s "$APPLY_LOG" ] || fail 'valid rules were not passed to the nft transaction'

valid_bridge="$fixture_root/valid-bridge.nft"
printf '%s\n' \
    'table bridge bridge_test {' \
    '}' >"$valid_bridge"
echo '  -> supported bridge table headers pass the editor contract'
firewall_validate_file "$valid_bridge" \
    || fail 'a valid bridge table definition was rejected'
[ "$(firewall_tables "$valid_bridge")" = 'bridge bridge_test' ] \
    || fail 'firewall_tables did not recognize the valid bridge table header'

check_before="$(cksum "$CHECK_LOG")"
apply_before="$(cksum "$APPLY_LOG")"
runtime_before="$(cksum "$WLOC_FIREWALL_RUNTIME")"
unsafe_index=0

for command in \
    'flush ruleset' \
    'delete table inet fw4' \
    'include "/etc/nftables.d/*.nft"' \
    'add table inet wloc_legacy' \
    'replace rule inet fw4 input handle 1 accept'; do
    unsafe_index=$((unsafe_index + 1))
    source="$fixture_root/unsafe-$unsafe_index.nft"
    printf '%s\n' "$command" >"$source"
    echo "  -> reject unsafe command: $command"
    if firewall_validate_file "$source"; then
        fail "unsafe command passed validation: $command"
    fi
    [ "${firewall_error_code:-}" = unsupported_firewall_command ] \
        || fail "unsafe command returned the wrong validation error: $command"
    [ "$check_before" = "$(cksum "$CHECK_LOG")" ] \
        || fail "unsafe command reached nft --check: $command"
    if firewall_apply_file "$source"; then
        fail "unsafe command was applied: $command"
    fi
    [ "${firewall_error_code:-}" = unsupported_firewall_command ] \
        || fail "unsafe command returned the wrong Apply error: $command"
    [ "$apply_before" = "$(cksum "$APPLY_LOG")" ] \
        || fail "unsafe command reached the nft transaction: $command"
    [ "$runtime_before" = "$(cksum "$WLOC_FIREWALL_RUNTIME")" ] \
        || fail "unsafe command changed the applied snapshot: $command"
    [ ! -e "$WLOC_FIREWALL_RUNTIME_NEXT" ] \
        || fail "unsafe command left a staged snapshot: $command"
done

split_family="$fixture_root/invalid-split-family.nft"
printf '%s\n' \
    'table' \
    'inet split_family {' \
    '}' >"$split_family"
split_name="$fixture_root/invalid-split-name.nft"
printf '%s\n' \
    'table inet' \
    'split_name {' \
    '}' >"$split_name"

for source in "$split_family" "$split_name"; do
    echo "  -> reject split table header: $source"
    if firewall_validate_file "$source"; then
        fail "split table header passed validation: $source"
    fi
    [ "${firewall_error_code:-}" = unsupported_firewall_command ] \
        || fail "split table header returned the wrong validation error: $source"
    [ "$check_before" = "$(cksum "$CHECK_LOG")" ] \
        || fail "split table header reached nft --check: $source"
done

echo 'WLOC firewall command safety tests: PASS'
