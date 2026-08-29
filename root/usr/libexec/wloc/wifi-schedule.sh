#!/bin/sh

# Temporarily disables the wireless UCI section resolved from each WLOC iface.
# Changes are kept in UCI's runtime delta and are never committed to wireless.

STATE_DIR="${WLOC_SCHEDULE_STATE_DIR:-/var/run/wloc}"
STATE_FILE="$STATE_DIR/wifi-schedule.state"
DESIRED_FILE="$STATE_DIR/wifi-schedule.desired.$$"
WLOC_SCHEDULE_DESIRED_ERROR=0

. "${WLOC_LIB_FUNCTIONS:-/lib/functions.sh}"
AP_LIB=${WLOC_AP_LIB_PATH:-/usr/libexec/wloc/ap-lib.sh}

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

state_contains() {
    local section="$1"
    [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ] || return 1
    awk -F '|' -v wanted="$section" '$1 == wanted { found = 1; exit } END { exit !found }' "$STATE_FILE"
}

desired_contains() {
    grep -F -x -q "$1" "$DESIRED_FILE" 2>/dev/null
}

desired_add() {
    local section="$1"
    desired_contains "$section" && return 0
    if ! printf '%s\n' "$section" >>"$DESIRED_FILE"; then
        WLOC_SCHEDULE_DESIRED_ERROR=1
        return 1
    fi
}

reload_wifi() {
    wifi reload >/dev/null 2>&1 || logger -t wloc-schedule 'wifi reload failed; scheduled AP state may be delayed'
}

warn_unresolved_iface() {
    logger -t wloc-schedule "interface \"$1\" is unavailable; scheduled state was not changed" 2>/dev/null || true
}

schedule_error() {
    logger -t wloc-schedule "$1" 2>/dev/null || true
}

collect_active_wifi() {
    local section="$1" enabled schedule_enabled start end iface wireless_section
    case "$section" in ''|*[!A-Za-z0-9_-]*) return 0;; esac
    config_get_bool enabled "$section" enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get_bool schedule_enabled "$section" schedule_enabled 0
    [ "$schedule_enabled" -eq 1 ] || return 0
    config_get start "$section" schedule_start ''
    config_get end "$section" schedule_end ''
    valid_time "$start" && valid_time "$end" || return 0
    window_active "$start" "$end" || return 0
    config_get iface "$section" iface ''
    [ -n "$iface" ] || {
        warn_unresolved_iface '<empty>'
        return 0
    }
    load_ap_lib
    wireless_section="$(wloc_ap_find_section_by_ifname "$iface" 2>/dev/null || true)"
    [ -n "$wireless_section" ] || {
        warn_unresolved_iface "$iface"
        return 0
    }
    desired_add "$wireless_section"
}

remember_original() {
    local section="$1" original state_next
    state_contains "$section" && return 0
    if uci -q get "wireless.$section.disabled" >/dev/null 2>&1; then
        original="$(uci -q get "wireless.$section.disabled")"
    else
        original='__unset__'
    fi
    mkdir -p "$STATE_DIR" || return 1
    [ ! -e "$STATE_FILE" ] || [ -f "$STATE_FILE" ] || return 1
    state_next="$STATE_FILE.new.$$"
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE" >"$state_next" || {
            rm -f "$state_next"
            return 1
        }
    else
        : >"$state_next" || return 1
    fi
    printf '%s|%s\n' "$section" "$original" >>"$state_next" || {
        rm -f "$state_next"
        return 1
    }
    if ! mv -f "$state_next" "$STATE_FILE"; then
        rm -f "$state_next"
        return 1
    fi
}

restore_entry() {
    local section="$1" original="$2" current
    case "$original" in
        __unset__)
            if uci -q get "wireless.$section.disabled" >/dev/null 2>&1; then
                if uci -q delete "wireless.$section.disabled"; then
                    WLOC_SCHEDULE_CHANGED=1
                    return 0
                fi
                return 1
            fi
            return 0
            ;;
        *)
            current="$(uci -q get "wireless.$section.disabled" 2>/dev/null || true)"
            if [ "$current" != "$original" ]; then
                if uci -q set "wireless.$section.disabled=$original"; then
                    WLOC_SCHEDULE_CHANGED=1
                    return 0
                fi
                return 1
            fi
            return 0
            ;;
    esac
}

reconcile() {
    local section original current new_state reconcile_failed=0 state_write_failed=0
    mkdir -p "$STATE_DIR" || {
        schedule_error 'unable to create schedule state directory; scheduled state was not changed'
        return 1
    }
    WLOC_SCHEDULE_CHANGED=0
    WLOC_SCHEDULE_DESIRED_ERROR=0
    : >"$DESIRED_FILE" || {
        schedule_error 'unable to create schedule desired-state file; scheduled state was not changed'
        return 1
    }
    config_load wloc || return 1
    WLOC_NOW_MINUTES="$(time_minutes "$(date +%H:%M)")"
    config_foreach collect_active_wifi wifi
    if [ "$WLOC_SCHEDULE_DESIRED_ERROR" -ne 0 ]; then
        rm -f "$DESIRED_FILE"
        schedule_error 'unable to build schedule desired state; scheduled state was not changed'
        return 1
    fi

    while IFS= read -r section; do
        [ -n "$section" ] || continue
        if ! remember_original "$section"; then
            schedule_error "unable to save original state for wireless.$section; scheduled state was not changed"
            reconcile_failed=1
            continue
        fi
        current="$(uci -q get "wireless.$section.disabled" 2>/dev/null || true)"
        case "$current" in
            1|yes|true) ;;
            *)
                if uci -q set "wireless.$section.disabled=1"; then
                    WLOC_SCHEDULE_CHANGED=1
                else
                    schedule_error "unable to disable wireless.$section; scheduled state will be retried"
                    reconcile_failed=1
                fi
                ;;
        esac
    done <"$DESIRED_FILE"

    new_state="$STATE_FILE.new.$$"
    : >"$new_state" || {
        schedule_error 'unable to stage schedule state; scheduled state will be retried'
        return 1
    }
    if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
        while IFS='|' read -r section original; do
            [ -n "$section" ] || continue
            if desired_contains "$section"; then
                if ! printf '%s|%s\n' "$section" "$original" >>"$new_state"; then
                    state_write_failed=1
                    break
                fi
            else
                if ! restore_entry "$section" "$original"; then
                    if ! printf '%s|%s\n' "$section" "$original" >>"$new_state"; then
                        state_write_failed=1
                        break
                    fi
                    reconcile_failed=1
                fi
            fi
        done <"$STATE_FILE"
    fi
    if [ "$state_write_failed" -eq 1 ]; then
        rm -f "$new_state"
        schedule_error 'unable to commit schedule state; previous state was retained'
        return 1
    fi
    if [ -s "$new_state" ]; then
        if ! mv -f "$new_state" "$STATE_FILE"; then
            rm -f "$new_state"
            schedule_error 'unable to commit schedule state; previous state was retained'
            return 1
        fi
    else
        rm -f "$new_state"
        if ! rm -f "$STATE_FILE" 2>/dev/null; then
            schedule_error 'unable to clear schedule state; previous state was retained'
            return 1
        fi
    fi
    if [ "$WLOC_SCHEDULE_CHANGED" -eq 1 ]; then
        reload_wifi
    fi
    return "$reconcile_failed"
}

restore_state() {
    local section original next_state restore_failed=0 state_write_failed=0
    [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ] || return 0
    WLOC_SCHEDULE_CHANGED=0
    next_state="$STATE_FILE.next.$$"
    : >"$next_state" || {
        schedule_error 'unable to stage schedule restoration; original state was retained'
        return 1
    }
    while IFS='|' read -r section original; do
        [ -n "$section" ] || continue
        if ! restore_entry "$section" "$original"; then
            if ! printf '%s|%s\n' "$section" "$original" >>"$next_state"; then
                state_write_failed=1
                break
            fi
            restore_failed=1
        fi
    done <"$STATE_FILE"
    if [ "$state_write_failed" -eq 1 ]; then
        rm -f "$next_state"
        schedule_error 'unable to commit schedule restoration; original state was retained'
        return 1
    fi
    if [ -s "$next_state" ]; then
        if ! mv -f "$next_state" "$STATE_FILE"; then
            rm -f "$next_state"
            schedule_error 'unable to commit schedule restoration; original state was retained'
            return 1
        fi
    else
        rm -f "$next_state"
        if ! rm -f "$STATE_FILE" 2>/dev/null; then
            schedule_error 'unable to clear restored schedule state; original state was retained'
            return 1
        fi
    fi
    [ "$WLOC_SCHEDULE_CHANGED" -eq 1 ] && reload_wifi
    return "$restore_failed"
}

cleanup() {
    local rc=0
    trap - EXIT INT TERM HUP
    restore_state || rc=$?
    rm -f "$DESIRED_FILE"
    return "$rc"
}

run_loop() {
    local second delay
    trap cleanup EXIT INT TERM HUP
    while :; do
        reconcile || true
        second="$(decimal "$(date +%S)")"
        delay=$((60 - second))
        [ "$delay" -ge 1 ] || delay=60
        sleep "$delay" || break
    done
}

case "${1:-}" in
    run) run_loop;;
    reconcile)
        reconcile
        rc=$?
        rm -f "$DESIRED_FILE"
        exit "$rc"
        ;;
    stop|restore)
        restore_state
        rc=$?
        rm -f "$DESIRED_FILE"
        exit "$rc"
        ;;
*) echo "usage: $0 {run|reconcile|stop}" >&2; exit 2;;
esac
