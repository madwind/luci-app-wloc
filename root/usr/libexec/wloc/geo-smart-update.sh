#!/bin/sh

. /usr/share/libubox/jshn.sh

GEO=/usr/libexec/wloc/geo-update.sh

smart_update() {
    local output ok ready known available
    output="$($GEO check 2>&1)" || {
        printf '%s\n' "$output"
        return 1
    }
    json_load "$output" 2>/dev/null || {
        printf '%s\n' '{"ok":false,"error":"GeoIP check returned invalid JSON"}'
        return 1
    }
    json_get_var ok ok
    json_get_var ready ready
    json_get_var known update_known
    json_get_var available update_available
    case "$ok" in 1|true) ;; *) printf '%s\n' "$output"; return 1;; esac
    case "$ready" in 1|true)
        case "$known" in 1|true)
            case "$available" in 0|false|'') printf '%s\n' "$output"; return 0;; esac
            ;;
        esac
        ;;
    esac
    exec "$GEO" start
}

case "${1:-}" in
    update) smart_update;;
    auto)
        [ "$(uci -q get wloc.main.geoip_auto_update 2>/dev/null || echo 0)" = '1' ] || {
            printf '%s\n' '{"ok":true,"kind":"geoip","status":"disabled","automatic":true}'
            exit 0
        }
        smart_update
        ;;
    *) printf '%s\n' 'usage: geo-smart-update.sh {update|auto}' >&2; exit 2;;
esac
