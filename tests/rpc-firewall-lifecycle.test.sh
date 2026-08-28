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
persistent="$fixture_root/firewall.saved.nft"
candidate="$fixture_root/firewall.candidate.nft"
printf '%s' 'table inet saved {
}' >"$persistent"
printf '%s' 'table inet candidate {
}' >"$candidate"

fake_jshn="$fixture_root/jshn.sh"
cat >"$fake_jshn" <<'EOF'
json_init() { :; }
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
json_add_boolean() { :; }
json_add_int() { :; }
json_add_string() { :; }
json_dump() { :; }
EOF

rules_helper="$fixture_root/rules.sh"
cat >"$rules_helper" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$rules_helper"

CHECK_RC=0
APPLY_RC=0
nft() {
	case "${1:-}" in
		--check) return "$CHECK_RC";;
		--file) return "$APPLY_RC";;
		list) return 0;;
		*) return 0;;
	esac
}

pidof() { return 1; }

export WLOC_RPC_SOURCE=1
export WLOC_JSHN_PATH="$fake_jshn"
export WLOC_FIREWALL_HELPER_PATH="$HELPER"
export WLOC_RULES_HELPER="$rules_helper"
export WLOC_RUNTIME_DIR="$runtime"
export WLOC_FIREWALL_PATH="$persistent"
export WLOC_FIREWALL_RUNTIME="$runtime/firewall.applied.nft"
export WLOC_FIREWALL_CANDIDATE="$runtime/firewall.candidate.nft"
. "$RPC"

echo '  -> apply updates runtime only'
firewall_config="$(cat "$candidate")"
emit_firewall_apply
cmp -s "$candidate" "$WLOC_FIREWALL_RUNTIME" \
	|| fail 'apply did not update the applied runtime snapshot'
cmp -s "$persistent" "$candidate" \
	&& fail 'apply changed the persistent firewall file'
cmp -s "$candidate" "$FIREWALL_CANDIDATE" \
	|| fail 'apply did not record the candidate snapshot'

echo '  -> syntax failure keeps both snapshots'
CHECK_RC=1
firewall_config='table inet rejected {'
emit_firewall_apply
cmp -s "$candidate" "$WLOC_FIREWALL_RUNTIME" \
	|| fail 'syntax failure replaced the applied runtime snapshot'
cmp -s "$candidate" "$FIREWALL_CANDIDATE" \
	|| fail 'syntax failure replaced the candidate snapshot'
CHECK_RC=0

echo '  -> transaction failure keeps both snapshots'
APPLY_RC=1
firewall_config='table inet rejected {'
emit_firewall_apply
cmp -s "$candidate" "$WLOC_FIREWALL_RUNTIME" \
	|| fail 'transaction failure replaced the applied runtime snapshot'
cmp -s "$candidate" "$FIREWALL_CANDIDATE" \
	|| fail 'transaction failure replaced the candidate snapshot'
APPLY_RC=0

echo '  -> save ignores un-applied request content'
firewall_config='table inet ignored {'
emit_firewall_save
cmp -s "$candidate" "$persistent" \
	|| fail 'save did not copy the applied snapshot to persistent storage'

echo 'WLOC RPC firewall tests: PASS'
