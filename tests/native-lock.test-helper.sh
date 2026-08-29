#!/bin/sh

# Test double for OpenWrt's lock utility. The production helper invokes the
# native lock command; this fixture only supplies the same -n/-u interface on
# hosts that do not have OpenWrt's BusyBox applet.

mode="${1:-}"
lock_file="${2:-}"
lock_dir="${lock_file}.test-held"
holder_file="${lock_file}.test-holder"

case "$mode" in
    -n)
        if ! mkdir "$lock_dir" 2>/dev/null; then
            exit 1
        fi
        : >"$lock_file"
        (
            trap 'rmdir "$lock_dir" 2>/dev/null; exit 0' INT TERM HUP
            while :; do
                sleep 0.1
            done
        ) &
        printf '%s\n' "$!" >"$holder_file"
        ;;
    -u)
        if [ -r "$holder_file" ]; then
            holder="$(cat "$holder_file" 2>/dev/null || true)"
            case "$holder" in
                ''|*[!0-9]*) ;;
                *) kill "$holder" 2>/dev/null || true;;
            esac
            rm -f "$holder_file"
        fi
        attempt=0
        while [ -d "$lock_dir" ] && [ "$attempt" -lt 20 ]; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
        rmdir "$lock_dir" 2>/dev/null || true
        ;;
    *)
        exit 2
        ;;
esac
