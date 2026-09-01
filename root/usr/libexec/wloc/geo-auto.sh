#!/bin/sh

. /usr/share/libubox/jshn.sh

CRONTAB=/etc/crontabs/root
TAG=wloc-geoip-auto-weekly
SMART=/usr/libexec/wloc/geo-smart-update.sh
LOG=/var/log/wloc/geo-auto-update.log

flag() {
    [ "$(uci -q get wloc.main.geoip_auto_update 2>/dev/null || echo 0)" = '1' ] && printf '1' || printf '0'
}

reload_cron() {
    if pidof crond >/dev/null 2>&1; then
        /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
}

remove_schedule() {
    [ -f "$CRONTAB" ] || return 0
    sed -i "/$TAG/d" "$CRONTAB" || return 1
    reload_cron
}

sync_schedule() {
    mkdir -p /etc/crontabs /var/log/wloc || return 1
    touch "$CRONTAB" || return 1
    sed -i "/$TAG/d" "$CRONTAB" || return 1
    if [ "$(flag)" = '1' ]; then
        printf '%s\n' "23 4 * * 0 $SMART auto >>$LOG 2>&1 # $TAG" >>"$CRONTAB" || return 1
    fi
    reload_cron
}

emit_status() {
    json_init
    json_add_boolean ok 1
    json_add_boolean enabled "$(flag)"
    json_dump
}

set_auto() {
    local enabled="$1"
    case "$enabled" in 1|true|yes|on) enabled=1;; 0|false|no|off|'') enabled=0;; *) return 2;; esac
    uci -q set "wloc.main.geoip_auto_update=$enabled" || return 1
    uci -q commit wloc || return 1
    sync_schedule || return 1
    emit_status
}

case "${1:-}" in
    status) emit_status;;
    set) set_auto "$2";;
    sync) sync_schedule && emit_status;;
    remove) remove_schedule && emit_status;;
    *) printf '%s\n' 'usage: geo-auto.sh {status|set <0|1>|sync|remove}' >&2; exit 2;;
esac
