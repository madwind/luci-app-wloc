#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/root/usr/libexec/wloc/firewall.sh"

fail() {
	echo "WLOC firewall removal tests: FAIL: $*" >&2
	exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
runtime="$fixture_root/runtime"
mkdir -p "$runtime"
persistent="$fixture_root/firewall.saved.nft"
applied="$runtime/firewall.applied.nft"
staged="$runtime/firewall.applied.nft.next"

printf '%s\n' \
	'table inet wloc_a {' \
	'}' \
	'table bridge wloc_b {' \
	'}' >"$applied"
printf '%s\n' 'table inet persistent_only {' '}' >"$persistent"
printf '%s\n' 'table inet unrelated {' '}' >"$staged"

check_log="$fixture_root/check.log"
apply_log="$fixture_root/apply.log"
: >"$check_log"
: >"$apply_log"
CHECK_RC=0
APPLY_RC=0

nft() {
	case "${1:-}" in
		list)
			[ "${2:-}" = table ] || return 1
			case "${3:-}:${4:-}" in
				inet:wloc_a|bridge:wloc_b|inet:unrelated|inet:persistent_only) return 0;;
				*) return 1;;
			esac
			;;
		--check)
			cat "$3" >>"$check_log"
			return "$CHECK_RC"
			;;
		--file)
			cat "$2" >>"$apply_log"
			return "$APPLY_RC"
			;;
		*) return 1;;
	esac
}

export WLOC_RUNTIME_DIR="$runtime"
export WLOC_FIREWALL_RUNTIME="$applied"
export WLOC_FIREWALL_RUNTIME_NEXT="$staged"
export WLOC_FIREWALL_PATH="$persistent"
WLOC_FIREWALL_HELPER_SOURCE=1
. "$HELPER"

echo '  -> remove only tables declared by the applied ruleset'
firewall_remove_runtime || fail 'runtime table removal failed'
grep -Fqx 'delete table inet wloc_a' "$check_log" \
	|| fail 'inet table was not checked for removal'
grep -Fqx 'delete table bridge wloc_b' "$check_log" \
	|| fail 'bridge table was not checked for removal'
grep -Fqx 'delete table inet wloc_a' "$apply_log" \
	|| fail 'inet table was not removed'
grep -Fqx 'delete table bridge wloc_b' "$apply_log" \
	|| fail 'bridge table was not removed'
if grep -Fq 'unrelated' "$check_log" "$apply_log"; then
	fail 'unrelated nftables table was selected for removal'
fi
[ ! -e "$applied" ] || fail 'applied snapshot was not removed after cleanup'
[ ! -e "$staged" ] || fail 'staged snapshot was not removed after cleanup'

echo '  -> fallback to persistent rules when no applied snapshot exists'
: >"$check_log"
: >"$apply_log"
firewall_remove_runtime || fail 'persistent fallback removal failed'
grep -Fqx 'delete table inet persistent_only' "$apply_log" \
	|| fail 'persistent fallback table was not removed'

echo '  -> command scripts are best effort'
command_script="$fixture_root/firewall.commands.nft"
printf '%s\n' 'flush table inet unrelated' >"$command_script"
firewall_remove_file "$command_script" \
	|| fail 'best-effort command script cleanup failed'
echo 'WLOC firewall removal tests: PASS'
