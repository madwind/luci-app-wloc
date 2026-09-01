#!/bin/sh

# Persistently manages scheduled WLOC AP state in /etc/config/wireless.
# The configured and runtime AP state is checked on startup and every 30 minutes.

. "${WLOC_LIB_FUNCTIONS:-/lib/functions.sh}"
AP_LIB=${WLOC_AP_LIB_PATH:-/usr/libexec/wloc/ap-lib.sh}
WLOC_SCHEDULE_CHANGED=0
WLOC_SCHEDULE_FAILED=0
WLOC_SCHEDULE_RUNTIME_MISMATCH=0

load_ap_lib() {
    [ "${WLOC_AP_LIB_LOADED:-0}" -eq 1 ] || . "$AP_LIB"
}

decimal() {
    local value="$1"
    value="${value#0}"
    [ -n "$value" ] || value=0
    printf '%s' "$value"
}

valid_time() {
    case "$1" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0;;
        *) return 1;;
    esac
}

time_minutes() {
    local value="$1" hour minute
    hour="${value%:*}"
    minute="${value#*:}"
    printf '%s' "$(( $(decimal "$hour") * 60 + $(decimal "$minute") ))"
}

window_active() {
    local start="$1" end="$2" start_minutes end_minutes now_minutes
    start_minutes="$(time_minutes "$start")"
    end_minutes="$(time_minutes "$end")"
    now_minutes="${WLOC_NOW_MINUTES:-$(time_minutes "$(date +%H:%M)")}"
    [ "$start_minutes" -eq "$end_minutes" ] && return 0
    if [ "$start_minutes" -lt "$end_minutes" ]; then
        [ "$now_minutes" -ge "$start_minutes" ] && [ "$now_minutes" -lt "$end_minutes" ]
    else
        [ "$now_minutes" -ge "$start_minutes" ] || [ "$now_minutes" -lt "$end_minutes" ]
    fi
}

valid_country() {
    case "$1" in
        [A-Za-z][A-Za-z]) return 0;;
        *) return 1;;
    esac
}

uppercase_country() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

schedule_error() {
    logger -t wlocd "wifi schedule: $1" 2>/dev/null || true
}

warn_unresolved_iface() {
    schedule_error "interface \"$1\" is unavailable; scheduled state was not changed"
}

set_wireless_value() {
    local key="$1" value="$2" description="$3" current
    current="$(uci -q get "$key" 2>/dev/null || true)"
    [ "$current" = "$value" ] && return 0
    if uci -q set "$key=$value"; then
        WLOC_SCHEDULE_CHANGED=1
        return 0
    fi
    schedule_error "unable to set $description; scheduled state will be retried"
    WLOC_SCHEDULE_FAILED=1
    return 1
}

reconcile_wifi() {
    local section="$1" enabled schedule_enabled start end iface wireless_section device desired current country current_country
    case "$section" in ''|*[!A-Za-z0-9_-]*) return 0;; esac

    config_get_bool enabled "$section" enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get_bool schedule_enabled "$section" schedule_enabled 0
    [ "$schedule_enabled" -eq 1 ] || return 0

    config_get start "$section" schedule_start ''
    config_get end "$section" schedule_end ''
    if ! valid_time "$start" || ! valid_time "$end"; then
        schedule_error "invalid schedule for WLOC rule $section"
        WLOC_SCHEDULE_FAILED=1
        return 0
    fi

    config_get iface "$section" iface ''
    [ -n "$iface" ] || {
        warn_unresolved_iface '<empty>'
        WLOC_SCHEDULE_FAILED=1
        return 0
    }

    load_ap_lib
    wireless_section="$(wloc_ap_find_section_by_ifname "$iface" 2>/dev/null || true)"
    [ -n "$wireless_section" ] || {
        warn_unresolved_iface "$iface"
        WLOC_SCHEDULE_FAILED=1
        return 0
    }

    device="$(uci -q get "wireless.$wireless_section.device" 2>/dev/null || true)"
    case "$device" in
        ''|*[!A-Za-z0-9_-]*)
            schedule_error "wireless.$wireless_section has no valid wifi-device; scheduled state was not changed"
            WLOC_SCHEDULE_FAILED=1
            return 0
            ;;
    esac

    if window_active "$start" "$end"; then
        desired=1
    else
        desired=0
    fi

    current="$(uci -q get "wireless.$wireless_section.disabled" 2>/dev/null || true)"
    if [ "$desired" -eq 1 ]; then
        case "$current" in
            1|yes|true) ;;
            *) set_wireless_value "wireless.$wireless_section.disabled" 1 "wireless.$wireless_section.disabled" ;;
        esac
        return 0
    fi

    case "$current" in
        0|no|false|'') ;;
        *) set_wireless_value "wireless.$wireless_section.disabled" 0 "wireless.$wireless_section.disabled" ;;
    esac

    config_get country "$section" country ''
    [ -n "$country" ] || return 0
    if ! valid_country "$country"; then
        schedule_error "invalid country code for WLOC rule $section: $country"
        WLOC_SCHEDULE_FAILED=1
        return 0
    fi
    country="$(uppercase_country "$country")"
    current_country="$(uci -q get "wireless.$device.country" 2>/dev/null || true)"
    [ "$current_country" = "$country" ] ||
        set_wireless_value "wireless.$device.country" "$country" "wireless.$device.country"
}

verify_wifi_runtime() {
    local section="$1" enabled schedule_enabled start end iface desired runtime_active
    case "$section" in ''|*[!A-Za-z0-9_-]*) return 0;; esac

    config_get_bool enabled "$section" enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get_bool schedule_enabled "$section" schedule_enabled 0
    [ "$schedule_enabled" -eq 1 ] || return 0

    config_get start "$section" schedule_start ''
    config_get end "$section" schedule_end ''
    valid_time "$start" && valid_time "$end" || return 0

    config_get iface "$section" iface ''
    [ -n "$iface" ] || return 0

    if window_active "$start" "$end"; then
        desired=0
    else
        desired=1
    fi

    load_ap_lib
    if wloc_ap_get_hostapd_status "$iface" >/dev/null 2>&1; then
        runtime_active=1
    else
        runtime_active=0
    fi

    [ "$runtime_active" -eq "$desired" ] && return 0

    WLOC_SCHEDULE_RUNTIME_MISMATCH=1
    if [ "$desired" -eq 1 ]; then
        schedule_error "runtime state mismatch for $iface: expected enabled; reloading WiFi"
    else
        schedule_error "runtime state mismatch for $iface: expected disabled; reloading WiFi"
    fi
}

reload_wifi() {
    if wifi reload >/dev/null 2>&1; then
        return 0
    fi
    schedule_error 'wifi reload failed; committed wireless state could not be applied'
    return 1
}

reconcile() {
    WLOC_SCHEDULE_CHANGED=0
    WLOC_SCHEDULE_FAILED=0
    WLOC_SCHEDULE_RUNTIME_MISMATCH=0
    config_load wloc || return 1
    WLOC_NOW_MINUTES="$(time_minutes "$(date +%H:%M)")"
    config_foreach reconcile_wifi wifi

    if [ "$WLOC_SCHEDULE_CHANGED" -eq 1 ]; then
        if ! uci -q commit wireless; then
            schedule_error 'unable to commit wireless configuration; scheduled state will be retried'
            return 1
        fi
        reload_wifi || WLOC_SCHEDULE_FAILED=1
    else
        config_foreach verify_wifi_runtime wifi
        if [ "$WLOC_SCHEDULE_RUNTIME_MISMATCH" -eq 1 ]; then
            reload_wifi || WLOC_SCHEDULE_FAILED=1
        fi
    fi

    return "$WLOC_SCHEDULE_FAILED"
}

seconds_until_next_check() {
    local minute second elapsed delay
    minute="$(decimal "$(date +%M)")"
    second="$(decimal "$(date +%S)")"
    elapsed=$(( (minute % 30) * 60 + second ))
    delay=$((1800 - elapsed))
    [ "$delay" -ge 1 ] || delay=1800
    printf '%s' "$delay"
}

run_loop() {
    local delay
    while :; do
        reconcile || true
        delay="$(seconds_until_next_check)"
        sleep "$delay" || break
    done
}

case "${1:-}" in
    run) run_loop;;
    reconcile) reconcile;;
    *) echo "usage: $0 {run|reconcile}" >&2; exit 2;;
esac
