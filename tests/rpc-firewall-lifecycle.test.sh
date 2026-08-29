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
applied_source="$fixture_root/firewall.applied-input.nft"
printf '%s' 'table inet saved {
}' >"$persistent"
printf '%s' 'table inet applied {
}' >"$applied_source"

fake_jshn="$fixture_root/jshn.sh"
cat >"$fake_jshn" <<'EOF'
json_init() {
	response_ok=''
	response_runtime_ready=''
	response_recovering=''
	response_warning=''
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
	if [ "$1" = warning ]; then response_warning="$2"; fi
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
firewall_config='table inet rejected {'
emit_firewall_apply
cmp -s "$applied_source" "$WLOC_FIREWALL_RUNTIME" \
	|| fail 'syntax failure replaced the applied runtime snapshot'
CHECK_RC=0

echo '  -> transaction failure keeps both snapshots'
APPLY_RC=1
firewall_config='table inet rejected {'
emit_firewall_apply
cmp -s "$applied_source" "$WLOC_FIREWALL_RUNTIME" \
	|| fail 'transaction failure replaced the applied runtime snapshot'
APPLY_RC=0

echo '  -> save ignores un-applied request content'
firewall_config='table inet ignored {'
emit_firewall_save
cmp -s "$applied_source" "$persistent" \
	|| fail 'save did not copy the applied snapshot to persistent storage'

echo 'WLOC RPC firewall tests: PASS'
