#!/bin/sh

. /usr/share/libubox/jshn.sh

STATE_DIR=/var/run/wloc
STATE="$STATE_DIR/update.json"
LOCK="$STATE_DIR/update.lock"
PACKAGE=luci-app-wloc
REPO=madwind/luci-app-wloc
API_URL="https://api.github.com/repos/$REPO/releases/latest"
UCLIENT_FETCH=/bin/uclient-fetch

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

installed_version() {
    local line token
    line="$(apk list -I "$PACKAGE" 2>/dev/null | head -n 1)"
    token="${line%% *}"
    case "$token" in
        "$PACKAGE"-*) printf '%s\n' "${token#"$PACKAGE"-}";;
    esac
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

version_relation() {
    apk version -t "$1" "$2" 2>/dev/null | tr -d '\r\n'
}

write_state() {
    mkdir -p "$STATE_DIR"
    json_dump >"$STATE.tmp.$$" || return 1
    chmod 0600 "$STATE.tmp.$$" 2>/dev/null || true
    mv -f "$STATE.tmp.$$" "$STATE"
}

read_state() {
    [ -s "$STATE" ] && cat "$STATE" || printf '%s\n' '{"status":"idle"}'
}

emit_error() {
    json_init
    json_add_boolean ok 0
    json_add_string status failed
    json_add_string error "$1"
    json_dump
}

save_result() {
    local ok="$1" status="$2" installed="$3" latest="$4" available="$5" error="$6"
    json_init
    json_add_boolean ok "$ok"
    json_add_string status "$status"
    [ -z "$installed" ] || json_add_string installed_version "$installed"
    [ -z "$latest" ] || json_add_string latest_version "$latest"
    [ -z "$available" ] || json_add_boolean update_available "$available"
    [ -z "$error" ] || json_add_string error "$error"
    json_add_int checked "$(date +%s)"
    write_state || true
    json_dump
}

fetch_to() {
    local url="$1" path="$2"
    [ -x "$UCLIENT_FETCH" ] || return 127
    rm -f "$path"
    "$UCLIENT_FETCH" -T 20 -O "$path" "$url" >/dev/null 2>&1
}

probe() {
    local installed suffix release_json tag latest sha_url sha_file relation available
    installed="$(installed_version)"
    [ -n "$installed" ] || { emit_error 'Unable to determine installed WLOC version.'; return 1; }
    suffix="$(asset_suffix)" || { emit_error 'Unable to determine OpenWrt target.'; return 1; }

    mkdir -p "$STATE_DIR"
    release_json="$STATE_DIR/release.json.$$"
    if ! fetch_to "$API_URL" "$release_json"; then
        rm -f "$release_json"
        emit_error 'Unable to fetch the latest WLOC release metadata.'
        return 1
    fi
    json_load_file "$release_json" 2>/dev/null || {
        rm -f "$release_json"
        emit_error 'The latest WLOC release metadata is invalid.'
        return 1
    }
    rm -f "$release_json"
    json_get_var tag tag_name
    case "$tag" in
        v*) latest="${tag#v}";;
        *) emit_error 'The latest WLOC release tag is invalid.'; return 1;;
    esac

    sha_url="https://github.com/$REPO/releases/download/$tag/$PACKAGE-$latest-$suffix.apk.sha256"
    sha_file="$STATE_DIR/check.sha256.$$"
    if ! fetch_to "$sha_url" "$sha_file"; then
        rm -f "$sha_file"
        emit_error "The latest release does not provide a package for target $suffix."
        return 1
    fi
    rm -f "$sha_file"

    relation="$(version_relation "$latest" "$installed")"
    case "$relation" in
        '>') available=1;;
        '='|'<' ) available=0;;
        *) emit_error 'Unable to compare WLOC package versions.'; return 1;;
    esac

    save_result 1 idle "$installed" "$latest" "$available" ''
}

status() {
    local installed cached
    installed="$(installed_version)"
    cached="$(read_state)"
    json_load "$cached" 2>/dev/null || json_init
    json_add_boolean ok 1
    json_add_string installed_version "$installed"
    json_dump
}

install_update() {
    local probe_json ok installed latest available suffix tag asset base apk sha_file expected actual log
    if ! mkdir "$LOCK" 2>/dev/null; then
        emit_error 'Another WLOC update is already in progress.'
        return 1
    fi
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

    probe_json="$(probe)" || { printf '%s\n' "$probe_json"; return 1; }
    json_load "$probe_json" 2>/dev/null || { emit_error 'Unable to read update check result.'; return 1; }
    json_get_var ok ok
    json_get_var installed installed_version
    json_get_var latest latest_version
    json_get_var available update_available
    case "$available" in 1|true|yes) ;; *) printf '%s\n' "$probe_json"; return 0;; esac

    suffix="$(asset_suffix)" || { emit_error 'Unable to determine OpenWrt target.'; return 1; }
    tag="v$latest"
    asset="$PACKAGE-$latest-$suffix.apk"
    base="https://github.com/$REPO/releases/download/$tag"
    apk="$STATE_DIR/$asset"
    sha_file="$apk.sha256"

    json_init
    json_add_boolean ok 1
    json_add_string status downloading
    json_add_string installed_version "$installed"
    json_add_string latest_version "$latest"
    json_add_boolean update_available 1
    write_state || true

    if ! fetch_to "$base/$asset" "$apk" || ! fetch_to "$base/$asset.sha256" "$sha_file"; then
        rm -f "$apk" "$sha_file"
        save_result 0 failed "$installed" "$latest" 1 'Unable to download the WLOC update package.'
        return 1
    fi

    expected="$(awk '{print $1; exit}' "$sha_file" | tr 'A-F' 'a-f')"
    actual="$(sha256sum "$apk" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -f "$apk" "$sha_file"
        save_result 0 failed "$installed" "$latest" 1 'WLOC update SHA256 verification failed.'
        return 1
    fi

    json_init
    json_add_boolean ok 1
    json_add_string status installing
    json_add_string installed_version "$installed"
    json_add_string latest_version "$latest"
    json_add_boolean update_available 1
    write_state || true

    log="$STATE_DIR/apk-update.log.$$"
    if ! apk add --allow-untrusted "$apk" >"$log" 2>&1; then
        local detail
        detail="$(tail -n 5 "$log" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
        rm -f "$apk" "$sha_file" "$log"
        save_result 0 failed "$installed" "$latest" 1 "APK install failed: $(trim "$detail")"
        return 1
    fi
    rm -f "$apk" "$sha_file" "$log"

    /etc/init.d/wloc restart >/dev/null 2>&1 || true
    installed="$(installed_version)"
    save_result 1 done "$installed" "$latest" 0 ''
}

case "$1" in
    status) status;;
    check) probe;;
    install) install_update;;
    *) emit_error 'Unknown update command.'; exit 1;;
esac
