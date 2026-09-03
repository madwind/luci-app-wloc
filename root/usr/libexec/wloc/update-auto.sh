#!/bin/sh

. /usr/share/libubox/jshn.sh

CRONTAB=/etc/crontabs/root
TAG=wloc-update-weekly
UPDATER=/usr/libexec/wloc/update.sh
SCHEDULE='17 4 * * 0'

flag() {
    local value
    value="$(uci -q get "wloc.main.$1" 2>/dev/null || true)"
    [ "$value" = 1 ] && printf '1' || printf '0'
}

reload_cron() {
    pidof crond >/dev/null 2>&1 || return 0
    /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
}

remove_schedule() {
    [ -f "$CRONTAB" ] || return 0
    sed -i "/$TAG/d" "$CRONTAB" || return 1
    reload_cron
}

sync_schedule() {
    mkdir -p /etc/crontabs || return 1
    touch "$CRONTAB" || return 1
    sed -i "/$TAG/d" "$CRONTAB" || return 1
    if [ "$(flag update_check_enabled)" = 1 ]; then
        printf '%s\n' "$SCHEDULE $0 run >/dev/null 2>&1 # $TAG" >>"$CRONTAB" || return 1
    fi
    reload_cron
}

emit_status() {
    local scheduled=0
    [ -f "$CRONTAB" ] && grep -Fq "# $TAG" "$CRONTAB" && scheduled=1
    json_init
    json_add_boolean ok 1
    json_add_boolean check_enabled "$(flag update_check_enabled)"
    json_add_boolean wloc "$(flag wloc_auto_update)"
    json_add_boolean scheduled "$scheduled"
    json_add_string schedule "$SCHEDULE"
    json_dump
}

set_flag() {
    local option="$1" enabled="$2"
    case "$enabled" in 1|true|yes|on) enabled=1;; 0|false|no|off|'') enabled=0;; *) return 2;; esac
    uci -q set "wloc.main.$option=$enabled" || return 1
    uci -q commit wloc || return 1
}

run_checks() {
    local raw available
    raw="$($UPDATER check 2>&1)" || { logger -t wloc-update "scheduled update check failed: $raw"; return 1; }
    [ "$(flag wloc_auto_update)" = 1 ] || return 0
    raw="$($UPDATER status 2>/dev/null)" || return 1
    json_load "$raw" 2>/dev/null || return 1
    json_get_var available update_available
    [ "$available" = 1 ] || return 0
    $UPDATER install >/dev/null 2>&1 || { logger -t wloc-update 'automatic WLOC update could not start'; return 1; }
}

case "${1:-}" in
    status) emit_status;;
    set-check) set_flag update_check_enabled "$2" && sync_schedule && emit_status;;
    set-auto) set_flag wloc_auto_update "$2" && emit_status;;
    sync) sync_schedule && emit_status;;
    remove) remove_schedule && emit_status;;
    run) run_checks;;
    *) printf '%s\n' 'usage: update-auto.sh {status|set-check <0|1>|set-auto <0|1>|sync|remove|run}' >&2; exit 2;;
esac
