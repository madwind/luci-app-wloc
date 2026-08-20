#!/bin/sh

# Temporarily disables configured AP interfaces during parent WiFi/AP windows.
# Changes are kept in UCI's runtime delta and are never committed to wireless.

STATE_DIR=/var/run/wloc
STATE_FILE="$STATE_DIR/wifi-schedule.state"
ACTIVE_FILE="$STATE_DIR/wifi-schedule.active.$$"
DESIRED_FILE="$STATE_DIR/wifi-schedule.desired.$$"

. /lib/functions.sh

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
	local start="$1" end="$2" now start_minutes end_minutes now_minutes
	now="$(date +%H:%M)"
	start_minutes="$(time_minutes "$start")"
	end_minutes="$(time_minutes "$end")"
	now_minutes="$(time_minutes "$now")"
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

collect_active_parent() {
	local section="$1" enabled schedule_enabled start end network ssid bssid wireless_section wireless_ifname
	case "$section" in ''|*[!A-Za-z0-9_-]*) return 0;; esac
	config_get_bool enabled "$section" enabled 1
	[ "$enabled" -eq 1 ] || return 0
	config_get_bool schedule_enabled "$section" schedule_enabled 0
	[ "$schedule_enabled" -eq 1 ] || return 0
	config_get start "$section" schedule_start ''
	config_get end "$section" schedule_end ''
	valid_time "$start" && valid_time "$end" || return 0
	window_active "$start" "$end" || return 0
	config_get network "$section" network ssid
	config_get ssid "$section" ssid ''
	config_get bssid "$section" bssid ''
	config_get wireless_section "$section" wireless_section ''
	config_get wireless_ifname "$section" wireless_ifname ''
	bssid="$(printf '%s' "$bssid" | tr 'A-F' 'a-f')"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$section" "$network" "$ssid" "$bssid" "$wireless_section" "$wireless_ifname" >>"$ACTIVE_FILE"
}

collect_matching_interface() {
	local section="$1" mode ssid bssid macaddr device ifname parent network parent_ssid parent_bssid parent_section parent_ifname match
	case "$section" in ''|*[!A-Za-z0-9_-]*) return 0;; esac
	config_get mode "$section" mode ap
	case "$mode" in ap|ap-wds) ;; *) return 0;; esac
	config_get ssid "$section" ssid ''
	config_get bssid "$section" bssid ''
	config_get macaddr "$section" macaddr ''
	config_get device "$section" device ''
	config_get ifname "$section" ifname ''
	bssid="$(printf '%s' "$bssid" | tr 'A-F' 'a-f')"
	macaddr="$(printf '%s' "$macaddr" | tr 'A-F' 'a-f')"
	while IFS="$(printf '\t')" read -r parent network parent_ssid parent_bssid parent_section parent_ifname; do
		[ -n "$parent" ] || continue
		match=0
		case "$network" in
			any) match=1;;
			ssid) [ -n "$parent_ssid" ] && [ "$ssid" = "$parent_ssid" ] && match=1;;
			bssid)
				[ -n "$parent_section" ] && [ "$section" = "$parent_section" ] && match=1
				[ -n "$parent_ifname" ] && [ "$ifname" = "$parent_ifname" ] && match=1
				[ -n "$parent_ifname" ] && [ "$device" = "$parent_ifname" ] && match=1
				[ -n "$parent_bssid" ] && { [ "$bssid" = "$parent_bssid" ] || [ "$macaddr" = "$parent_bssid" ]; } && match=1
				;;
		esac
		[ "$match" -eq 1 ] && { desired_add "$section"; break; }
	done <"$ACTIVE_FILE"
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
	config_foreach collect_active_parent wifi
	config_load wireless || return 1
	config_foreach collect_matching_interface wifi-iface

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
	# Reload only when the effective schedule target or disabled flag changed.
	if [ "$WLOC_SCHEDULE_CHANGED" -eq 1 ] || [ "$old_state" != "$new_state_contents" ]; then
		reload_wifi
	fi
}

restore_state() {
	local section original
	[ -s "$STATE_FILE" ] || return 0
	while IFS='|' read -r section original; do
		[ -n "$section" ] || continue
		restore_entry "$section" "$original"
	done <"$STATE_FILE"
	rm -f "$STATE_FILE"
	reload_wifi
}

cleanup() {
	trap - EXIT INT TERM HUP
	restore_state
	rm -f "$ACTIVE_FILE" "$DESIRED_FILE"
}

run_loop() {
	trap cleanup EXIT INT TERM HUP
	while :; do
		reconcile || true
		sleep 30 || break
	done
}

case "${1:-}" in
	run) run_loop;;
	reconcile) reconcile; rm -f "$ACTIVE_FILE" "$DESIRED_FILE";;
	stop|restore) restore_state; rm -f "$ACTIVE_FILE" "$DESIRED_FILE";;
	*) echo "usage: $0 {run|reconcile|stop}" >&2; exit 2;;
esac
