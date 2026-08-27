#!/bin/sh

# Temporarily disables the wireless UCI section resolved from each WLOC SSID.
# Changes are kept in UCI's runtime delta and are never committed to wireless.

STATE_DIR="${WLOC_SCHEDULE_STATE_DIR:-/var/run/wloc}"
STATE_FILE="$STATE_DIR/wifi-schedule.state"
ACTIVE_FILE="$STATE_DIR/wifi-schedule.active.$$"
DESIRED_FILE="$STATE_DIR/wifi-schedule.desired.$$"

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
	[ -s "$STATE_FILE" ] || return 1
	awk -F '|' -v wanted="$section" '$1 == wanted { found = 1; exit } END { exit !found }' "$STATE_FILE"
}

desired_contains() {
	grep -F -x -q "$1" "$DESIRED_FILE" 2>/dev/null
}

desired_add() {
	local section="$1"
	desired_contains "$section" || printf '%s\n' "$section" >>"$DESIRED_FILE"
}

reload_wifi() {
	wifi reload >/dev/null 2>&1 || logger -t wloc-schedule 'wifi reload failed; scheduled AP state may be delayed'
}

warn_unresolved_ssid() {
	logger -t wloc-schedule "SSID \"$1\" is unavailable; scheduled state was not changed" 2>/dev/null || true
}

collect_active_wifi() {
	local section="$1" enabled schedule_enabled start end ssid wireless_section
	case "$section" in ''|*[!A-Za-z0-9_-]*) return 0;; esac
	config_get_bool enabled "$section" enabled 1
	[ "$enabled" -eq 1 ] || return 0
	config_get_bool schedule_enabled "$section" schedule_enabled 0
	[ "$schedule_enabled" -eq 1 ] || return 0
	config_get start "$section" schedule_start ''
	config_get end "$section" schedule_end ''
	valid_time "$start" && valid_time "$end" || return 0
	window_active "$start" "$end" || return 0
	config_get ssid "$section" ssid ''
	[ -n "$ssid" ] || {
		warn_unresolved_ssid '<empty>'
		return 0
	}
	load_ap_lib
	wireless_section="$(wloc_ap_find_section_by_ssid "$ssid" 2>/dev/null || true)"
	[ -n "$wireless_section" ] || {
		warn_unresolved_ssid "$ssid"
		return 0
	}
	desired_add "$wireless_section"
}

remember_original() {
	local section="$1" original
	state_contains "$section" && return 0
	if uci -q get "wireless.$section.disabled" >/dev/null 2>&1; then
		original="$(uci -q get "wireless.$section.disabled")"
	else
		original='__unset__'
	fi
	mkdir -p "$STATE_DIR"
	printf '%s|%s\n' "$section" "$original" >>"$STATE_FILE"
}

restore_entry() {
	local section="$1" original="$2" current
	case "$original" in
		__unset__)
			if uci -q get "wireless.$section.disabled" >/dev/null 2>&1; then
				uci -q delete "wireless.$section.disabled"
				WLOC_SCHEDULE_CHANGED=1
			fi
			;;
		*)
			current="$(uci -q get "wireless.$section.disabled" 2>/dev/null || true)"
			if [ "$current" != "$original" ]; then
				uci -q set "wireless.$section.disabled=$original"
				WLOC_SCHEDULE_CHANGED=1
			fi
			;;
	esac
}

reconcile() {
	local section original current new_state old_state new_state_contents
	mkdir -p "$STATE_DIR"
	old_state="$(cat "$STATE_FILE" 2>/dev/null || true)"
	WLOC_SCHEDULE_CHANGED=0
	: >"$ACTIVE_FILE"
	: >"$DESIRED_FILE"
	config_load wloc || return 1
	WLOC_NOW_MINUTES="$(time_minutes "$(date +%H:%M)")"
	config_foreach collect_active_wifi wifi

	while IFS= read -r section; do
		[ -n "$section" ] || continue
		remember_original "$section"
		current="$(uci -q get "wireless.$section.disabled" 2>/dev/null || true)"
		case "$current" in
			1|yes|true) ;;
			*) uci -q set "wireless.$section.disabled=1"; WLOC_SCHEDULE_CHANGED=1;;
		esac
	done <"$DESIRED_FILE"

	new_state="$STATE_FILE.new.$$"
	: >"$new_state"
	if [ -s "$STATE_FILE" ]; then
		while IFS='|' read -r section original; do
			[ -n "$section" ] || continue
			if desired_contains "$section"; then
				printf '%s|%s\n' "$section" "$original" >>"$new_state"
			else
				restore_entry "$section" "$original"
			fi
		done <"$STATE_FILE"
	fi
	if [ -s "$new_state" ]; then
		mv "$new_state" "$STATE_FILE"
	else
		rm -f "$new_state" "$STATE_FILE"
	fi
	new_state_contents="$(cat "$STATE_FILE" 2>/dev/null || true)"
	if [ "$WLOC_SCHEDULE_CHANGED" -eq 1 ] || [ "$old_state" != "$new_state_contents" ]; then
		reload_wifi
	fi
}

restore_state() {
	local section original
	[ -s "$STATE_FILE" ] || return 0
	WLOC_SCHEDULE_CHANGED=0
	while IFS='|' read -r section original; do
		[ -n "$section" ] || continue
		restore_entry "$section" "$original"
	done <"$STATE_FILE"
	rm -f "$STATE_FILE"
	[ "$WLOC_SCHEDULE_CHANGED" -eq 1 ] && reload_wifi
}

cleanup() {
	trap - EXIT INT TERM HUP
	restore_state
	rm -f "$ACTIVE_FILE" "$DESIRED_FILE"
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
	reconcile) reconcile; rm -f "$ACTIVE_FILE" "$DESIRED_FILE";;
	stop|restore) restore_state; rm -f "$ACTIVE_FILE" "$DESIRED_FILE";;
*) echo "usage: $0 {run|reconcile|stop}" >&2; exit 2;;
esac
