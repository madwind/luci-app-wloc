#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/root/etc/init.d/wloc"
RPC="$ROOT/root/usr/libexec/rpcd/luci.wloc"

fail() {
    echo "WLOC cleanup failure tests: FAIL: $*" >&2
    exit 1
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

rules_helper="$fixture_root/rules.sh"
cat >"$rules_helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$WLOC_TEST_RULES_OUTPUT" >&2
exit "$WLOC_TEST_RULES_RC"
EOF
chmod +x "$rules_helper"

firewall_helper="$fixture_root/firewall.sh"
: >"$firewall_helper"
chmod +x "$firewall_helper"

schedule_helper="$fixture_root/schedule.sh"
cat >"$schedule_helper" <<'EOF'
#!/bin/sh
[ -n "${WLOC_TEST_INIT_LOG:-}" ] && printf '%s\n' "$*" >>"$WLOC_TEST_INIT_LOG"
exit 0
EOF
chmod +x "$schedule_helper"

logger_log="$fixture_root/logger.log"
procd_log="$fixture_root/procd.log"
init_log="$fixture_root/init.log"
start_error="$fixture_root/start-error"
: >"$logger_log"
: >"$procd_log"
: >"$init_log"
export WLOC_TEST_INIT_LOG="$init_log"

# The init script is sourced after its rc.common shebang is removed so the
# service functions can be exercised with host-side stubs.
eval "$(sed '1d' "$INIT")"
RULES="$rules_helper"
FIREWALL_HELPER="$firewall_helper"
SCHEDULE="$schedule_helper"
FIREWALL="$fixture_root/firewall.nft"
START_ERROR="$start_error"

mkdir() {
    case "$*" in
        *'/var/run/wloc'*|*'/etc/wloc'*) :;;
        *) command mkdir "$@";;
    esac
}
rm() {
    case "$*" in
        *'/var/run/wloc'*|*'/etc/wloc'*) :;;
        *) command rm "$@";;
    esac
}
chmod() {
    case "$*" in
        *'/etc/wloc'*) :;;
        *) command chmod "$@";;
    esac
}
logger() { printf '%s\n' "$*" >>"$logger_log"; }
procd_open_instance() { printf '%s\n' "$1" >>"$procd_log"; }
procd_set_param() { :; }
procd_append_param() { :; }
procd_close_instance() { :; }
config_load() { :; }
config_get_bool() {
    local destination="$1" section="$2" option="$3" value=0
    [ "$section:$option" = 'main:enabled' ] && value=1
    eval "$destination=\$value"
}
config_get() {
    local destination="$1"
    eval "$destination=''"
}

export WLOC_TEST_RULES_RC=1
export WLOC_TEST_RULES_OUTPUT='managed firewall state could not be cleared'

echo '  -> start refuses to launch the daemon after cleanup failure'
if start_service; then
    fail 'start_service reported success after cleanup failure'
fi
grep -Fq 'managed firewall state could not be cleared' "$start_error" \
    || fail 'startup failure did not preserve the cleanup error'
if grep -Fqx daemon "$procd_log"; then
    fail 'start_service opened the daemon instance after cleanup failure'
fi

echo '  -> stop keeps cleanup failure visible'
if stop_service; then
    fail 'stop_service reported success after cleanup failure'
fi
grep -Fq 'firewall cleanup failed while stopping service' "$logger_log" \
    || fail 'stop_service did not log cleanup failure'
[ ! -s "$init_log" ] \
    || fail 'stop_service restored schedule state before procd killed the service'

echo '  -> service_stopped does not let cleanup failure get masked by rm'
if service_stopped; then
    fail 'service_stopped reported success after cleanup failure'
fi
[ "$(cat "$init_log")" = stop ] \
    || fail 'service_stopped did not retain schedule restore as the final fallback'

fake_jshn="$fixture_root/jshn.sh"
cat >"$fake_jshn" <<'EOF'
json_init() {
    response_ok=''
    response_error=''
    response_error_code=''
    response_detail=''
    response_status=''
    response_fingerprint=''
    response_profile_url=''
    json_fingerprint=''
}
json_load_file() {
    json_fingerprint="$(sed -n 's/.*"fingerprint_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1")"
}
json_get_var() {
    [ "$2" = fingerprint_sha256 ] || return 0
    eval "$1=\$json_fingerprint"
}
json_add_boolean() {
    [ "$1" = ok ] && response_ok="$2"
}
json_add_string() {
    case "$1" in
        error) response_error="$2";;
        error_code) response_error_code="$2";;
        detail) response_detail="$2";;
        status) response_status="$2";;
        fingerprint) response_fingerprint="$2";;
        profile_url) response_profile_url="$2";;
    esac
}
json_dump() { :; }
EOF

export WLOC_RPC_SOURCE=1
export WLOC_JSHN_PATH="$fake_jshn"
export WLOC_FIREWALL_HELPER_PATH="$firewall_helper"
export WLOC_RULES_HELPER="$rules_helper"
export WLOC_CA_KEY_PATH="$fixture_root/ca.key"
export WLOC_CA_DER_PATH="$fixture_root/ca.der"
export WLOC_CA_PEM_PATH="$fixture_root/ca.pem"
export WLOC_CAINFO_PATH="$fixture_root/ca.info.json"
export WLOC_CA_PROFILE_PATH="$fixture_root/wloc-ca.mobileconfig"
export WLOC_CA_REGENERATION_TIMEOUT_SECONDS=1
export WLOC_CA_REGENERATION_POLL_SECONDS=0
export WLOC_RUNTIME_DIR="$fixture_root"
export WLOC_FIREWALL_PATH="$fixture_root/firewall.nft"
export WLOC_FIREWALL_RUNTIME="$fixture_root/firewall.applied.nft"
export WLOC_STATUS_PATH="$fixture_root/status.json"
. "$RPC"

rm_log="$fixture_root/rm.log"
: >"$init_log"
: >"$rm_log"
rm() {
    [ "${WLOC_TEST_RM_RC:-0}" -eq 0 ] || return "$WLOC_TEST_RM_RC"
    case "$*" in
        *'/etc/wloc/ca.key'*|*'/www/wloc-ca.mobileconfig'*)
            printf '%s\n' "$*" >>"$rm_log"
            ;;
        *'/var/run/wloc'*|*'/etc/wloc'*)
            ;;
        *)
            command rm "$@"
            ;;
    esac
}
fake_enabled=0
uci() {
    [ "${1:-}" = '-q' ] && shift
    [ "${1:-}" = get ] && [ "${2:-}" = wloc.main.enabled ] || return 1
    printf '%s\n' "$fake_enabled"
}

echo '  -> regenerate CA rejects a disabled WLOC service without mutations'
fake_enabled=0
rpc_regenerate_ca
[ "$response_ok" = 0 ] || fail 'disabled regenerate CA did not return ok=false'
[ "$response_error_code" = service_disabled ] \
    || fail 'disabled regenerate CA returned the wrong error code'
[ "$response_error" = 'Unable to regenerate CA while WLOC is disabled.' ] \
    || fail 'disabled regenerate CA returned the wrong error message'
[ "$response_detail" = 'Enable WLOC before regenerating the CA.' ] \
    || fail 'disabled regenerate CA returned the wrong error detail'
[ ! -s "$init_log" ] || fail 'disabled regenerate CA called the init script'
[ ! -s "$rm_log" ] || fail 'disabled regenerate CA removed CA files'

echo '  -> regenerate CA preserves the daemon and CA when cleanup fails'
fake_enabled=1
rpc_regenerate_ca
[ "$response_ok" = 0 ] || fail 'cleanup RPC did not return ok=false'
[ "$response_error_code" = cleanup_failed ] \
    || fail 'regenerate CA returned the wrong error code'
[ "$response_detail" = "$WLOC_TEST_RULES_OUTPUT" ] \
    || fail 'regenerate CA did not preserve the helper error'
[ ! -s "$init_log" ] || fail 'regenerate CA stopped the daemon after cleanup failure'
[ ! -s "$rm_log" ] || fail 'regenerate CA removed CA files after cleanup failure'

ca_key="$fixture_root/ca.key"
ca_der="$fixture_root/ca.der"
ca_pem="$fixture_root/ca.pem"
ca_info="$fixture_root/ca.info.json"
ca_profile="$fixture_root/wloc-ca.mobileconfig"
daemon_state="$fixture_root/daemon-ready"
init_helper="$fixture_root/init-ca.sh"
cat >"$init_helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$WLOC_TEST_INIT_LOG"
case "${1:-}" in
    stop)
        [ "${WLOC_TEST_STOP_RC:-0}" -eq 0 ]
        ;;
    start)
        [ "${WLOC_TEST_START_RC:-0}" -eq 0 ] || exit "$WLOC_TEST_START_RC"
        if [ "${WLOC_TEST_GENERATE_CA:-0}" -eq 1 ]; then
            printf '%s\n' generated >"$WLOC_TEST_CA_KEY"
            printf '%s\n' generated >"$WLOC_TEST_CA_DER"
            printf '%s\n' generated >"$WLOC_TEST_CA_PEM"
            printf '{"fingerprint_sha256":"%s"}\n' \
                "$WLOC_TEST_CA_FINGERPRINT" >"$WLOC_TEST_CAINFO"
            printf '%s\n' generated >"$WLOC_TEST_CA_PROFILE"
            if [ "${WLOC_TEST_DAEMON_READY:-0}" -eq 1 ]; then
                : >"$WLOC_TEST_DAEMON_STATE"
            fi
        fi
        ;;
esac
EOF
chmod +x "$init_helper"
export WLOC_TEST_CA_KEY="$ca_key"
export WLOC_TEST_CA_DER="$ca_der"
export WLOC_TEST_CA_PEM="$ca_pem"
export WLOC_TEST_CAINFO="$ca_info"
export WLOC_TEST_CA_PROFILE="$ca_profile"
export WLOC_TEST_DAEMON_STATE="$daemon_state"
INIT="$init_helper"
service_daemon_running() {
    [ -e "$daemon_state" ]
}

write_ca_artifacts() {
    printf '%s\n' existing >"$ca_key"
    printf '%s\n' existing >"$ca_der"
    printf '%s\n' existing >"$ca_pem"
    printf '{"fingerprint_sha256":"%s"}\n' "$1" >"$ca_info"
    printf '%s\n' existing >"$ca_profile"
}

reset_regeneration_fixture() {
    export WLOC_TEST_RM_RC=0
    rm -f "$ca_key" "$ca_der" "$ca_pem" "$ca_info" "$ca_profile" "$daemon_state"
    : >"$init_log"
    response_ok=''
    response_error=''
    response_error_code=''
    response_detail=''
    response_status=''
    response_fingerprint=''
    export WLOC_TEST_STOP_RC=0
    export WLOC_TEST_START_RC=0
    export WLOC_TEST_GENERATE_CA=0
    export WLOC_TEST_DAEMON_READY=0
    export WLOC_TEST_CA_FINGERPRINT=''
}

export WLOC_TEST_RULES_RC=0

echo '  -> regenerate CA reports a start failure'
reset_regeneration_fixture
write_ca_artifacts AAA
export WLOC_TEST_START_RC=1
rpc_regenerate_ca
expected_init_log="$(printf '%s\n%s' stop start)"
[ "$response_ok" = 0 ] || fail 'start failure did not return ok=false'
[ "$response_error_code" = ca_regeneration_failed ] \
    || fail 'start failure returned the wrong error code'
[ "$response_detail" = 'WLOC did not restart after CA removal.' ] \
    || fail 'start failure returned the wrong detail'
[ "$(cat "$init_log")" = "$expected_init_log" ] \
    || fail 'start failure did not stop and start exactly once'

echo '  -> regenerate CA reports a removal failure'
reset_regeneration_fixture
write_ca_artifacts AAA
export WLOC_TEST_RM_RC=1
rpc_regenerate_ca
[ "$response_ok" = 0 ] || fail 'removal failure did not return ok=false'
[ "$response_error_code" = ca_regeneration_failed ] \
    || fail 'removal failure returned the wrong error code'
[ "$response_detail" = 'Unable to remove the previous CA files.' ] \
    || fail 'removal failure returned the wrong detail'
[ "$(cat "$init_log")" = stop ] \
    || fail 'removal failure continued to start the service'

echo '  -> regenerate CA rejects a daemon that is not ready'
reset_regeneration_fixture
write_ca_artifacts AAA
export WLOC_TEST_GENERATE_CA=1
export WLOC_TEST_DAEMON_READY=0
export WLOC_TEST_CA_FINGERPRINT=BBB
rpc_regenerate_ca
[ "$response_ok" = 0 ] || fail 'daemon-not-ready did not return ok=false'
[ "$response_error_code" = ca_regeneration_failed ] \
    || fail 'daemon-not-ready returned the wrong error code'
[ "$response_detail" = 'The replacement CA was not generated before the timeout.' ] \
    || fail 'daemon-not-ready returned the wrong detail'

echo '  -> regenerate CA rejects an unchanged fingerprint'
reset_regeneration_fixture
write_ca_artifacts AAA
export WLOC_TEST_GENERATE_CA=1
export WLOC_TEST_DAEMON_READY=1
export WLOC_TEST_CA_FINGERPRINT=AAA
rpc_regenerate_ca
[ "$response_ok" = 0 ] || fail 'unchanged fingerprint did not return ok=false'
[ "$response_error_code" = ca_regeneration_failed ] \
    || fail 'unchanged fingerprint returned the wrong error code'
[ "$response_detail" = 'The replacement CA fingerprint did not change.' ] \
    || fail 'unchanged fingerprint returned the wrong detail'

echo '  -> regenerate CA succeeds only after the replacement is ready'
reset_regeneration_fixture
write_ca_artifacts AAA
export WLOC_TEST_GENERATE_CA=1
export WLOC_TEST_DAEMON_READY=1
export WLOC_TEST_CA_FINGERPRINT=BBB
rpc_regenerate_ca
[ "$response_ok" = 1 ] || fail 'successful CA regeneration did not return ok=true'
[ "$response_status" = ready ] || fail 'successful CA regeneration returned the wrong status'
[ "$response_fingerprint" = BBB ] || fail 'successful CA regeneration returned the wrong fingerprint'
[ "$response_profile_url" = '/wloc-ca.mobileconfig' ] \
    || fail 'successful CA regeneration returned the wrong profile URL'
[ "$(cat "$init_log")" = "$expected_init_log" ] \
    || fail 'successful CA regeneration did not stop and start exactly once'

echo 'WLOC cleanup failure tests: PASS'
