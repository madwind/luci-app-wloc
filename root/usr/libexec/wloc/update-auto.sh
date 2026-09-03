#!/bin/sh

. /usr/share/libubox/jshn.sh

CRONTAB=/etc/crontabs/root
TAG=wloc-update-weekly
UPDATER=/usr/libexec/wloc/update.sh
SCHEDULE='17 4 * * 0'
SCHEDULE_MINUTE=17
SCHEDULE_HOUR=4
SCHEDULE_DOW=0

flag() {
    local value
    value="$(uci -q get "wloc.main.$1" 2>/dev/null || true)"
    [ "$value" = 1 ] && printf '1' || printf '0'
}

decimal() {
    local value="$1"
    case "$value" in 0*) value="${value#0}";; esac
    [ -n "$value" ] || value=0
    printf '%s' "$value"
}

days_in_month() {
    local year="$1" month="$2"
    case "$month" in
        1|3|5|7|8|10|12) printf '31';;
        4|6|9|11) printf '30';;
        2)
            if [ $((year % 400)) -eq 0 ] || { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; }; then
                printf '29'
            else
                printf '28'
            fi
            ;;
        *) return 1;;
    esac
}

next_check_local() {
    local fields year month day dow hour minute days dim
    fields="$(date '+%Y %m %d %w %H %M' 2>/dev/null)" || return 1
    set -- $fields
    [ "$#" -eq 6 ] || return 1

    year="$(decimal "$1")"
    month="$(decimal "$2")"
    day="$(decimal "$3")"
    dow="$(decimal "$4")"
    hour="$(decimal "$5")"
    minute="$(decimal "$6")"

    days=$(((SCHEDULE_DOW - dow + 7) % 7))
    if [ "$days" -eq 0 ] && { [ "$hour" -gt "$SCHEDULE_HOUR" ] || { [ "$hour" -eq "$SCHEDULE_HOUR" ] && [ "$minute" -ge "$SCHEDULE_MINUTE" ]; }; }; then
        days=7
    fi

    while [ "$days" -gt 0 ]; do
        dim="$(days_in_month "$year" "$month")" || return 1
        day=$((day + 1))
        if [ "$day" -gt "$dim" ]; then
            day=1
            month=$((month + 1))
            if [ "$month" -gt 12 ]; then
                month=1
                year=$((year + 1))
            fi
        fi
        days=$((days - 1))
    done

    printf '%04d-%02d-%02d %02d:%02d' "$year" "$month" "$day" "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE"
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
    local scheduled=0 next_check='' timezone=''
    [ -f "$CRONTAB" ] && grep -Fq "# $TAG" "$CRONTAB" && scheduled=1
    if [ "$scheduled" = 1 ]; then
        next_check="$(next_check_local 2>/dev/null || true)"
        timezone="$(date +%Z 2>/dev/null || true)"
    fi
    json_init
    json_add_boolean ok 1
    json_add_boolean check_enabled "$(flag update_check_enabled)"
    json_add_boolean wloc "$(flag wloc_auto_update)"
    json_add_boolean scheduled "$scheduled"
    json_add_string schedule "$SCHEDULE"
    json_add_string next_check "$next_check"
    json_add_string timezone "$timezone"
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
