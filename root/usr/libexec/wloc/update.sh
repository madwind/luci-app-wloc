#!/bin/sh

. /usr/share/libubox/jshn.sh

STATE_DIR=/tmp/wloc-update
STATE="$STATE_DIR/wloc.json"
LOCK="$STATE_DIR/wloc.lock"
LOG="$STATE_DIR/wloc.log"
VERSION_CACHE=/usr/share/wloc/installed-version
PACKAGE=luci-app-wloc
REPO=madwind/luci-app-wloc
API_URL="https://api.github.com/repos/$REPO/releases/latest"
UCLIENT_FETCH=/bin/uclient-fetch
UPDATER=/usr/libexec/wloc/update.sh

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

cached_installed_version() {
    local version
    [ -r "$VERSION_CACHE" ] || return 1
    IFS= read -r version <"$VERSION_CACHE" || return 1
    [ -n "$version" ] || return 1
    printf '%s\n' "$version"
}

installed_version() {
    local line token
    line="$(apk list -I "$PACKAGE" 2>/dev/null | head -n 1)"
    token="${line%% *}"
    case "$token" in "$PACKAGE"-*) printf '%s\n' "${token#"$PACKAGE"-}";; esac
}

board_target() {
    local raw target
    raw="$(ubus call system board 2>/dev/null)" || return 1
    json_load "$raw" 2>/dev/null || return 1
    json_select release 2>/dev/null || return 1
    json_get_var target target
    [ -n "$target" ] || return 1
    printf '%s\n' "$target"
}

asset_suffix() {
    local target
    target="$(board_target)" || return 1
    printf '%s\n' "$(printf '%s' "$target" | tr '/' '-')"
}

version_relation() { apk version -t "$1" "$2" 2>/dev/null | tr -d '\r\n'; }

fetch_to() {
    local url="$1" path="$2"
    [ -x "$UCLIENT_FETCH" ] || return 127
    rm -f "$path"
    "$UCLIENT_FETCH" -T 20 -O "$path" "$url" >/dev/null 2>&1
}

state_defaults() {
    st_status=idle; st_phase=''; st_pid=0; st_started=0; st_finished=0
    st_installed=''; st_latest=''; st_available=''; st_checked=0; st_check_ok=''
    st_last_check_error=''; st_last_update=0; st_updated=0; st_post_check_error=''
    st_error=''; st_message=''; st_release_tag=''; st_asset=''
}

load_state() {
    local cached
    state_defaults
    if [ -s "$STATE" ] && json_load_file "$STATE" 2>/dev/null; then
        json_get_var st_status status
        json_get_var st_phase phase
        json_get_var st_pid pid
        json_get_var st_started started
        json_get_var st_finished finished
        json_get_var st_installed installed_version
        json_get_var st_latest latest_version
        json_get_var st_available update_available
        json_get_var st_checked checked
        json_get_var st_check_ok check_ok
        json_get_var st_last_check_error last_check_error
        json_get_var st_last_update last_update
        json_get_var st_updated updated
        json_get_var st_post_check_error post_check_error
        json_get_var st_error error
        json_get_var st_message message
        json_get_var st_release_tag release_tag
        json_get_var st_asset asset
    fi
    [ -n "$st_status" ] || st_status=idle
    cached="$(cached_installed_version 2>/dev/null || true)"
    if [ -n "$cached" ]; then
        case "$st_status" in starting|running|stopping) [ -n "$st_installed" ] || st_installed="$cached";; *) st_installed="$cached";; esac
    fi
}

write_json_state() {
    mkdir -p "$STATE_DIR" || return 1
    json_dump >"$STATE.tmp.$$" || return 1
    chmod 0600 "$STATE.tmp.$$" 2>/dev/null || true
    mv -f "$STATE.tmp.$$" "$STATE"
}

save_state() {
    json_init
    json_add_string kind wloc
    json_add_string status "$st_status"
    [ -z "$st_phase" ] || json_add_string phase "$st_phase"
    case "$st_pid" in ''|*[!0-9]*) ;; *) [ "$st_pid" -le 0 ] || json_add_int pid "$st_pid";; esac
    case "$st_started" in ''|*[!0-9]*) ;; *) [ "$st_started" -le 0 ] || json_add_int started "$st_started";; esac
    case "$st_finished" in ''|*[!0-9]*) ;; *) [ "$st_finished" -le 0 ] || json_add_int finished "$st_finished";; esac
    [ -z "$st_installed" ] || json_add_string installed_version "$st_installed"
    [ -z "$st_latest" ] || json_add_string latest_version "$st_latest"
    case "$st_available" in 0|1) json_add_boolean update_available "$st_available";; esac
    case "$st_checked" in ''|*[!0-9]*) ;; *) [ "$st_checked" -le 0 ] || json_add_int checked "$st_checked";; esac
    case "$st_check_ok" in 0|1) json_add_boolean check_ok "$st_check_ok";; esac
    [ -z "$st_last_check_error" ] || json_add_string last_check_error "$st_last_check_error"
    case "$st_last_update" in ''|*[!0-9]*) ;; *) [ "$st_last_update" -le 0 ] || json_add_int last_update "$st_last_update";; esac
    json_add_boolean updated "$st_updated"
    [ -z "$st_post_check_error" ] || json_add_string post_check_error "$st_post_check_error"
    [ -z "$st_error" ] || json_add_string error "$st_error"
    [ -z "$st_message" ] || json_add_string message "$st_message"
    [ -z "$st_release_tag" ] || json_add_string release_tag "$st_release_tag"
    [ -z "$st_asset" ] || json_add_string asset "$st_asset"
    write_json_state
}

process_alive() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -gt 1 ] && kill -0 "$1" >/dev/null 2>&1; }
operation_active() { case "$st_status" in starting|running|stopping) process_alive "$st_pid";; *) return 1;; esac; }

normalize_stale_worker() {
    case "$st_status" in
        starting|running|stopping)
            if ! process_alive "$st_pid"; then
                st_status=failed; st_phase=failed; st_finished="$(date +%s)"; st_pid=0
                st_error='The WLOC update worker exited unexpectedly.'; st_message='Update failed'
                save_state || true
            fi
            ;;
    esac
}

emit_status() {
    load_state; normalize_stale_worker
    json_init
    json_add_boolean ok 1
    [ -z "$st_installed" ] || json_add_string installed_version "$st_installed"
    [ -z "$st_latest" ] || json_add_string latest_version "$st_latest"
    case "$st_available" in 0|1) json_add_boolean update_available "$st_available";; esac
    case "$st_checked" in ''|*[!0-9]*) ;; *) [ "$st_checked" -le 0 ] || json_add_int checked "$st_checked";; esac
    case "$st_check_ok" in 0|1) json_add_boolean check_ok "$st_check_ok";; esac
    [ -z "$st_last_check_error" ] || json_add_string last_check_error "$st_last_check_error"
    case "$st_last_update" in ''|*[!0-9]*) ;; *) [ "$st_last_update" -le 0 ] || json_add_int last_update "$st_last_update";; esac
    [ -z "$st_post_check_error" ] || json_add_string post_check_error "$st_post_check_error"
    json_add_object operation
    json_add_string status "$st_status"
    [ -z "$st_phase" ] || json_add_string phase "$st_phase"
    case "$st_pid" in ''|*[!0-9]*) ;; *) [ "$st_pid" -le 0 ] || json_add_int pid "$st_pid";; esac
    case "$st_started" in ''|*[!0-9]*) ;; *) [ "$st_started" -le 0 ] || json_add_int started "$st_started";; esac
    case "$st_finished" in ''|*[!0-9]*) ;; *) [ "$st_finished" -le 0 ] || json_add_int finished "$st_finished";; esac
    json_add_boolean updated "$st_updated"
    [ -z "$st_error" ] || json_add_string error "$st_error"
    [ -z "$st_message" ] || json_add_string message "$st_message"
    json_close_object
    json_dump
}

emit_error() { json_init; json_add_boolean ok 0; json_add_string error "$1"; json_dump; }

probe_release() {
    local release_json sha_file relation
    PROBE_OK=0; PROBE_ERROR=''; PROBE_INSTALLED="$(cached_installed_version 2>/dev/null || true)"
    [ -n "$PROBE_INSTALLED" ] || PROBE_INSTALLED="$(installed_version)"
    PROBE_LATEST=''; PROBE_AVAILABLE=''; PROBE_TAG=''; PROBE_SUFFIX=''; PROBE_ASSET=''
    [ -n "$PROBE_INSTALLED" ] || { PROBE_ERROR='Unable to determine installed WLOC version.'; return 1; }
    PROBE_SUFFIX="$(asset_suffix)" || { PROBE_ERROR='Unable to determine OpenWrt target.'; return 1; }
    mkdir -p "$STATE_DIR" || { PROBE_ERROR='Unable to create the WLOC update directory.'; return 1; }
    release_json="$STATE_DIR/release.json.$$"
    if ! fetch_to "$API_URL" "$release_json"; then rm -f "$release_json"; PROBE_ERROR='Unable to fetch the latest WLOC release metadata.'; return 1; fi
    json_load_file "$release_json" 2>/dev/null || { rm -f "$release_json"; PROBE_ERROR='The latest WLOC release metadata is invalid.'; return 1; }
    rm -f "$release_json"
    json_get_var PROBE_TAG tag_name
    case "$PROBE_TAG" in v*) PROBE_LATEST="${PROBE_TAG#v}";; *) PROBE_ERROR='The latest WLOC release tag is invalid.'; return 1;; esac
    PROBE_ASSET="$PACKAGE-$PROBE_LATEST-$PROBE_SUFFIX.apk"
    sha_file="$STATE_DIR/check.sha256.$$"
    if ! fetch_to "https://github.com/$REPO/releases/download/$PROBE_TAG/$PROBE_ASSET.sha256" "$sha_file"; then
        rm -f "$sha_file"; PROBE_ERROR="The latest release does not provide a package for target $PROBE_SUFFIX."; return 1
    fi
    rm -f "$sha_file"
    relation="$(version_relation "$PROBE_LATEST" "$PROBE_INSTALLED")"
    case "$relation" in '>') PROBE_AVAILABLE=1;; '='|'<') PROBE_AVAILABLE=0;; *) PROBE_ERROR='Unable to compare WLOC package versions.'; return 1;; esac
    PROBE_OK=1
}

apply_probe() {
    st_checked="$(date +%s)"; st_installed="$PROBE_INSTALLED"
    if [ "$PROBE_OK" -eq 1 ]; then
        st_check_ok=1; st_latest="$PROBE_LATEST"; st_available="$PROBE_AVAILABLE"
        st_release_tag="$PROBE_TAG"; st_asset="$PROBE_ASSET"; st_last_check_error=''
    else
        st_check_ok=0; st_last_check_error="$PROBE_ERROR"
    fi
}

check_update() {
    load_state
    if operation_active; then emit_error 'A WLOC update is already in progress.'; return 1; fi
    st_status=idle; st_phase=''; st_error=''; st_message=''; st_updated=0; st_finished=0
    if probe_release; then apply_probe; save_state || true; emit_status; return 0; fi
    apply_probe; save_state || true; emit_error "$PROBE_ERROR"; return 1
}

set_phase() { st_status=running; st_phase="$1"; st_pid=$$; st_message="$2"; st_error=''; save_state; }

worker_fail() {
    st_status=failed; st_phase=failed; st_finished="$(date +%s)"; st_error="$1"; st_message='Update failed'
    st_pid=0; st_updated=0; save_state || true; rmdir "$LOCK" 2>/dev/null || true; return 1
}

worker_done() {
    local updated="$1"
    st_status=done; st_phase=done; st_finished="$(date +%s)"; st_pid=0; st_updated="$updated"; st_error=''; st_message="$2"
    st_installed="$(cached_installed_version 2>/dev/null || true)"; [ -n "$st_installed" ] || st_installed="$(installed_version)"
    if [ -n "$st_installed" ] && [ -n "$st_latest" ]; then
        case "$(version_relation "$st_latest" "$st_installed")" in '>') st_available=1;; '='|'<') st_available=0;; esac
    fi
    [ "$updated" -eq 1 ] && st_last_update="$st_finished"
    save_state || true; rmdir "$LOCK" 2>/dev/null || true
}

worker_update() {
    local apk sha_file expected actual install_log detail
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
    load_state; st_pid=$$
    [ "$st_check_ok" = 1 ] && [ "$st_available" = 1 ] && [ -n "$st_release_tag" ] && [ -n "$st_asset" ] || {
        worker_fail 'No checked WLOC update is available. Run Check updates first.'; return 1;
    }
    apk="$STATE_DIR/$st_asset.tmp.$$"; sha_file="$apk.sha256"
    set_phase downloading 'Downloading WLOC package' || return 1
    if ! fetch_to "https://github.com/$REPO/releases/download/$st_release_tag/$st_asset" "$apk" || \
       ! fetch_to "https://github.com/$REPO/releases/download/$st_release_tag/$st_asset.sha256" "$sha_file"; then
        rm -f "$apk" "$sha_file"; worker_fail 'Unable to download the WLOC update package.'; return 1
    fi
    set_phase verifying 'Verifying WLOC package' || return 1
    expected="$(awk '{print $1; exit}' "$sha_file" | tr 'A-F' 'a-f')"
    actual="$(sha256sum "$apk" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')"
    if [ -z "$expected" ] || [ -z "$actual" ] || [ "$expected" != "$actual" ]; then
        rm -f "$apk" "$sha_file"; worker_fail 'WLOC update SHA256 verification failed.'; return 1
    fi
    set_phase installing 'Installing WLOC package' || return 1
    install_log="$STATE_DIR/apk-install.log.$$"
    if ! apk add --allow-untrusted --upgrade "$apk" >"$install_log" 2>&1; then
        detail="$(tail -n 6 "$install_log" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
        rm -f "$apk" "$sha_file" "$install_log"; worker_fail "APK install failed: $(trim "$detail")"; return 1
    fi
    rm -f "$apk" "$sha_file" "$install_log"
    /etc/init.d/wloc restart >/dev/null 2>&1 || true
    st_installed="$(cached_installed_version 2>/dev/null || true)"; [ -n "$st_installed" ] || st_installed="$(installed_version)"
    st_post_check_error=''
    if [ -z "$st_installed" ]; then st_post_check_error='Unable to verify the installed WLOC version after update.'
    elif [ -n "$st_latest" ] && [ "$(version_relation "$st_installed" "$st_latest")" = '<' ]; then st_post_check_error='The installed WLOC version is still older than the checked release version.'; fi
    worker_done 1 'WLOC updated successfully'
}

start_update() {
    local pid
    mkdir -p "$STATE_DIR" || { emit_error 'Unable to create the WLOC update directory.'; return 1; }
    load_state
    if operation_active; then emit_status; return 0; fi
    [ "$st_check_ok" = 1 ] && [ "$st_available" = 1 ] && [ -n "$st_release_tag" ] && [ -n "$st_asset" ] || {
        emit_error 'No checked WLOC update is available. Run Check updates first.'; return 1;
    }
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { emit_error 'Another WLOC update is starting.'; return 1; }
    st_status=starting; st_phase=starting; st_started="$(date +%s)"; st_finished=0; st_pid=0; st_updated=0
    st_post_check_error=''; st_error=''; st_message='Update started'
    save_state || { rmdir "$LOCK" 2>/dev/null || true; emit_error 'Unable to save WLOC update state.'; return 1; }
    "$UPDATER" worker </dev/null >>"$LOG" 2>&1 & pid=$!
    case "$pid" in ''|*[!0-9]*|0|1) rmdir "$LOCK" 2>/dev/null || true; st_status=failed; st_phase=failed; st_error='Unable to start the WLOC update worker.'; save_state || true; emit_error "$st_error"; return 1;; esac
    load_state
    if [ "$st_status" = starting ] && [ "$st_pid" -le 1 ] 2>/dev/null; then st_pid="$pid"; save_state || true; fi
    emit_status
}

worker_matches() {
    local command
    command="$(tr '\000' ' ' <"/proc/$1/cmdline" 2>/dev/null || true)"
    printf '%s' "$command" | grep -Fq "$UPDATER" && printf '%s' "$command" | grep -Fq 'worker'
}

collect_children() { local parent="$1" child; for child in $(cat "/proc/$parent/task/$parent/children" 2>/dev/null); do collect_children "$child"; printf '%s\n' "$child"; done; }
any_alive() { local pid="$1" child; shift; process_alive "$pid" && return 0; for child in "$@"; do process_alive "$child" && return 0; done; return 1; }

terminate_tree() {
    local pid="$1" children child attempt=0
    children="$(collect_children "$pid")"
    for child in $children; do kill -TERM "$child" >/dev/null 2>&1 || true; done
    kill -TERM "$pid" >/dev/null 2>&1 || true
    while [ "$attempt" -lt 3 ]; do set -- $children; any_alive "$pid" "$@" || return 0; sleep 1; attempt=$((attempt + 1)); done
    for child in $children; do process_alive "$child" && kill -KILL "$child" >/dev/null 2>&1 || true; done
    process_alive "$pid" && kill -KILL "$pid" >/dev/null 2>&1 || true
    set -- $children; ! any_alive "$pid" "$@"
}

stop_update() {
    local pid
    load_state
    case "$st_status" in starting|running|stopping) ;; *) emit_error 'No active WLOC update to stop.'; return 1;; esac
    pid="$st_pid"; process_alive "$pid" || { emit_error 'No active WLOC update to stop.'; return 1; }
    [ "$st_phase" != installing ] || { emit_error 'WLOC package installation cannot be stopped safely.'; return 1; }
    worker_matches "$pid" || { emit_error 'Refusing to stop an unexpected process.'; return 1; }
    st_status=stopping; st_phase=stopping; st_message='Stopping update'; st_error=''; save_state || true
    if ! terminate_tree "$pid"; then st_status=failed; st_phase=failed; st_finished="$(date +%s)"; st_error='Unable to stop the WLOC update worker.'; st_message='Update failed'; save_state || true; emit_error "$st_error"; return 1; fi
    rm -f "$STATE_DIR"/*.tmp."$pid".* "$STATE_DIR"/apk-install.log."$pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    st_status=stopped; st_phase=stopped; st_finished="$(date +%s)"; st_pid=0; st_updated=0; st_error=''; st_message='Update stopped'; save_state || true; emit_status
}

case "$1" in
    status) emit_status;;
    check) check_update;;
    install|start) start_update;;
    stop) stop_update;;
    worker) worker_update;;
    *) emit_error 'Unknown update command.'; exit 1;;
esac
