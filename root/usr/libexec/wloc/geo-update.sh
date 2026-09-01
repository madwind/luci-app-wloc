#!/bin/sh

. "${WLOC_JSHN_PATH:-/usr/share/libubox/jshn.sh}"

RUNTIME=${WLOC_RUNTIME_DIR:-/var/run/wloc}
STATE=${WLOC_GEOIP_STATE_PATH:-$RUNTIME/geoip-update.json}
LOCK=${WLOC_GEOIP_LOCK_PATH:-$RUNTIME/geoip-update.lock}
LOG_DIR=${WLOC_LOG_DIR:-/var/log/wloc}
UCLIENT_FETCH=${WLOC_UCLIENT_FETCH:-/bin/uclient-fetch}
DEFAULT_FILE=/usr/share/wloc/geoip.dat
DEFAULT_URL=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

geoip_file() {
    local value
    value="$(uci -q get wloc.main.geoip_file 2>/dev/null || true)"
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$DEFAULT_FILE"
}

geoip_url() {
    local value
    value="$(uci -q get wloc.main.geoip_url 2>/dev/null || true)"
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$DEFAULT_URL"
}

version_file() {
    printf '%s.version' "$(geoip_file)"
}

asset_ready() {
    local file size
    file="$(geoip_file)"
    [ -f "$file" ] || return 1
    size="$(wc -c <"$file" 2>/dev/null || echo 0)"
    case "$size" in ''|*[!0-9]*) size=0;; esac
    [ "$size" -ge 1024 ]
}

process_alive() {
    local value="$1"
    case "$value" in ''|*[!0-9]*) return 1;; esac
    [ "$value" -gt 1 ] 2>/dev/null && kill -0 "$value" 2>/dev/null
}

state_defaults() {
    status=idle
    pid=0
    started=0
    finished=0
    downloaded=0
    checked=0
    last_update=0
    latest_version=''
    local_version=''
    update_known=0
    update_available=0
    check_ok=0
    last_check_error=''
    error=''
}

state_load() {
    local vf
    state_defaults
    if [ -s "$STATE" ] && json_load_file "$STATE" 2>/dev/null; then
        json_get_var status status
        json_get_var pid pid
        json_get_var started started
        json_get_var finished finished
        json_get_var downloaded downloaded
        json_get_var checked checked
        json_get_var last_update last_update
        json_get_var latest_version latest_version
        json_get_var local_version local_version
        json_get_var update_known update_known
        json_get_var update_available update_available
        json_get_var check_ok check_ok
        json_get_var last_check_error last_check_error
        json_get_var error error
    fi
    vf="$(version_file)"
    if asset_ready && [ -s "$vf" ]; then
        local_version="$(head -n 1 "$vf" 2>/dev/null || true)"
    elif ! asset_ready; then
        local_version=''
    fi
    case "$pid" in ''|*[!0-9]*) pid=0;; esac
    case "$started" in ''|*[!0-9]*) started=0;; esac
    case "$finished" in ''|*[!0-9]*) finished=0;; esac
    case "$downloaded" in ''|*[!0-9]*) downloaded=0;; esac
    case "$checked" in ''|*[!0-9]*) checked=0;; esac
    case "$last_update" in ''|*[!0-9]*) last_update=0;; esac
    case "$update_known" in 1|true|yes) update_known=1;; *) update_known=0;; esac
    case "$update_available" in 1|true|yes) update_available=1;; *) update_available=0;; esac
    case "$check_ok" in 1|true|yes) check_ok=1;; *) check_ok=0;; esac
}

state_save() {
    local temporary
    mkdir -p "$RUNTIME" || return 1
    temporary="$(mktemp "$STATE.XXXXXX")" || return 1
    json_init
    json_add_string status "$status"
    json_add_int pid "$pid"
    json_add_int started "$started"
    json_add_int finished "$finished"
    json_add_int downloaded "$downloaded"
    json_add_int checked "$checked"
    json_add_int last_update "$last_update"
    json_add_string latest_version "$latest_version"
    json_add_string local_version "$local_version"
    json_add_boolean update_known "$update_known"
    json_add_boolean update_available "$update_available"
    json_add_boolean check_ok "$check_ok"
    json_add_string last_check_error "$last_check_error"
    json_add_string error "$error"
    json_dump >"$temporary" || { rm -f "$temporary"; return 1; }
    chmod 0600 "$temporary" 2>/dev/null || true
    mv -f "$temporary" "$STATE"
}

normalize_state() {
    case "$status" in
        starting|running|stopping)
            if [ "$pid" -gt 1 ] 2>/dev/null && ! process_alive "$pid"; then
                status=failed
                pid=0
                finished="$(date +%s)"
                [ -n "$error" ] || error='GeoIP update process ended unexpectedly.'
                state_save || true
                rmdir "$LOCK" 2>/dev/null || true
            fi
            ;;
    esac
}

emit_state() {
    local ready=0
    asset_ready && ready=1
    json_init
    json_add_boolean ok 1
    json_add_string kind geoip
    json_add_boolean ready "$ready"
    json_add_string status "$status"
    json_add_int pid "$pid"
    json_add_int started "$started"
    json_add_int finished "$finished"
    json_add_int downloaded "$downloaded"
    json_add_int checked "$checked"
    json_add_int last_update "$last_update"
    json_add_string local_version "$local_version"
    json_add_string latest_version "$latest_version"
    json_add_boolean update_known "$update_known"
    [ "$update_known" -eq 1 ] && json_add_boolean update_available "$update_available"
    json_add_boolean check_ok "$check_ok"
    json_add_string last_check_error "$last_check_error"
    json_add_string error "$error"
    json_add_string path "$(geoip_file)"
    json_add_string url "$(geoip_url)"
    json_dump
}

emit_error() {
    json_init
    json_add_boolean ok 0
    json_add_string kind geoip
    json_add_string error "$1"
    json_dump
}

release_version() {
    sed -n 's#.*\/releases\/download\/\([^/[:space:]]*\)/.*#\1#p' | tail -n 1
}

probe_remote() {
    local url output
    url="$(geoip_url)"
    case "$url" in https://*) ;;
        *) PROBE_ERROR='GeoIP source URL must use HTTPS.'; return 1;;
    esac
    [ -x "$UCLIENT_FETCH" ] || { PROBE_ERROR='uclient-fetch is unavailable.'; return 1; }
    if ! output="$($UCLIENT_FETCH -s -T 10 "$url" 2>&1)"; then
        PROBE_ERROR="GeoIP check failed for $url: ${output:-network request failed}"
        return 1
    fi
    REMOTE_VERSION="$(printf '%s\n' "$output" | release_version)"
    [ -n "$REMOTE_VERSION" ] || {
        PROBE_ERROR="GeoIP check for $url did not expose a release version."
        return 1
    }
}

check_geoip() {
    state_load
    normalize_state
    case "$status" in starting|running|stopping)
        emit_error 'A GeoIP update is already in progress.'
        return
        ;;
    esac

    checked="$(date +%s)"
    if probe_remote; then
        check_ok=1
        last_check_error=''
        latest_version="$REMOTE_VERSION"
        if [ -n "$local_version" ]; then
            update_known=1
            [ "$local_version" = "$latest_version" ] && update_available=0 || update_available=1
        else
            update_known=0
            update_available=0
        fi
    else
        check_ok=0
        last_check_error="$PROBE_ERROR"
    fi
    status=idle
    error=''
    state_save || { emit_error 'Unable to save GeoIP update state.'; return; }
    emit_state
}

worker_stop() {
    [ -z "${fetch_pid:-}" ] || kill "$fetch_pid" 2>/dev/null || true
    rm -f "${temporary:-}" "${error_file:-}"
    rmdir "$LOCK" 2>/dev/null || true
    state_load
    status=stopped
    pid=0
    finished="$(date +%s)"
    downloaded=0
    error=''
    state_save || true
    exit 0
}

worker_fail() {
    local message="$1"
    rm -f "${temporary:-}" "${error_file:-}"
    rmdir "$LOCK" 2>/dev/null || true
    status=failed
    pid=0
    finished="$(date +%s)"
    downloaded=0
    error="$message"
    state_save || true
    exit 1
}

worker_geoip() {
    local file url directory code size source_version detail version_path version_tmp
    trap worker_stop TERM INT
    state_load
    status=running
    pid=$$
    [ "$started" -gt 0 ] 2>/dev/null || started="$(date +%s)"
    error=''
    downloaded=0
    state_save || exit 1

    file="$(geoip_file)"
    url="$(geoip_url)"
    case "$url" in https://*) ;;
        *) worker_fail 'GeoIP source URL must use HTTPS.';;
    esac
    directory="${file%/*}"
    [ "$directory" = "$file" ] && directory='.'
    mkdir -p "$directory" || worker_fail "Unable to create $directory."
    mkdir -p "$LOG_DIR" || true

    source_version=''
    if probe_remote; then source_version="$REMOTE_VERSION"; fi

    temporary="${file}.wloc-download.$$"
    error_file="$RUNTIME/geoip-fetch-error.$$"
    rm -f "$temporary" "$error_file"
    $UCLIENT_FETCH -T 30 -O "$temporary" "$url" >/dev/null 2>"$error_file" &
    fetch_pid=$!

    while process_alive "$fetch_pid"; do
        size="$(wc -c <"$temporary" 2>/dev/null || echo 0)"
        case "$size" in ''|*[!0-9]*) size=0;; esac
        downloaded="$size"
        status=running
        pid=$$
        state_save || true
        sleep 1 || true
    done
    wait "$fetch_pid" && code=0 || code=$?
    fetch_pid=''
    if [ "$code" -ne 0 ]; then
        detail="$(tail -n 1 "$error_file" 2>/dev/null || true)"
        worker_fail "GeoIP download failed for $url: ${detail:-uclient-fetch exit $code}"
    fi

    size="$(wc -c <"$temporary" 2>/dev/null || echo 0)"
    case "$size" in ''|*[!0-9]*) size=0;; esac
    [ "$size" -ge 1024 ] || worker_fail 'Downloaded GeoIP file is empty or implausibly small.'
    mv -f "$temporary" "$file" || worker_fail "Unable to replace $file."
    chmod 0644 "$file" 2>/dev/null || true
    rm -f "$error_file"

    version_path="${file}.version"
    if [ -n "$source_version" ]; then
        version_tmp="${version_path}.tmp.$$"
        printf '%s\n' "$source_version" >"$version_tmp" && chmod 0644 "$version_tmp" 2>/dev/null && mv -f "$version_tmp" "$version_path" || rm -f "$version_tmp"
    fi

    rmdir "$LOCK" 2>/dev/null || true
    finished="$(date +%s)"
    checked="$finished"
    last_update="$finished"
    local_version="$source_version"
    latest_version="$source_version"
    check_ok=1
    last_check_error=''
    if [ -n "$source_version" ]; then
        update_known=1
        update_available=0
    else
        update_known=0
        update_available=0
    fi
    status=done
    pid=0
    downloaded=0
    error=''
    state_save || true
}

start_geoip() {
    state_load
    normalize_state
    case "$status" in starting|running|stopping)
        emit_state
        return
        ;;
    esac
    mkdir -p "$RUNTIME" "$LOG_DIR" || { emit_error 'Unable to create GeoIP runtime directory.'; return; }
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { emit_error 'Another GeoIP update is starting.'; return; }

    status=starting
    pid=0
    started="$(date +%s)"
    finished=0
    downloaded=0
    error=''
    state_save || { rmdir "$LOCK" 2>/dev/null || true; emit_error 'Unable to save GeoIP update state.'; return; }

    "$0" worker >>"$LOG_DIR/geoip-update.log" 2>&1 </dev/null &
    pid=$!
    state_save || true
    emit_state
}

stop_geoip() {
    state_load
    normalize_state
    case "$status" in
        starting|running|stopping)
            if [ "$pid" -gt 1 ] 2>/dev/null && process_alive "$pid"; then
                status=stopping
                state_save || true
                kill "$pid" 2>/dev/null || true
            else
                status=stopped
                pid=0
                finished="$(date +%s)"
                state_save || true
                rmdir "$LOCK" 2>/dev/null || true
            fi
            ;;
    esac
    emit_state
}

status_geoip() {
    state_load
    normalize_state
    emit_state
}

case "${1:-}" in
    status) status_geoip;;
    check) check_geoip;;
    start) start_geoip;;
    stop) stop_geoip;;
    worker) worker_geoip;;
    *) printf '%s\n' 'usage: geo-update.sh {status|check|start|stop|worker}' >&2; exit 2;;
esac
