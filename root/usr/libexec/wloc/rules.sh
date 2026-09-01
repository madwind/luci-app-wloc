#!/bin/sh
# Fixed ingress-interface set and configurable IPv4 TPROXY policy-routing lifecycle.

set -e

. /lib/functions.sh

INGRESS_FAMILY=bridge
INGRESS_TABLE=wloc
INGRESS_SET=target_ingress_interfaces
ROUTING_HELPER=${WLOC_ROUTING_HELPER:-/usr/libexec/wloc/routing.sh}

WLOC_ROUTING_HELPER_SOURCE=1
. "$ROUTING_HELPER"

clear_ingress_interfaces() {
    if nft list set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1; then
        nft flush set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1 || return 1
    fi
}

cleanup() {
    local rc=0
    clear_ingress_interfaces || rc=1
    if ! routing_deactivate; then
        printf '%s\n' "wloc: ${routing_error:-unable to deactivate TPROXY policy routing}" >&2
        rc=1
    fi
    return "$rc"
}

reset() {
    local rc=0
    clear_ingress_interfaces || rc=1
    if ! routing_reset; then
        printf '%s\n' "wloc: ${routing_error:-unable to reset TPROXY policy routing}" >&2
        rc=1
    fi
    return "$rc"
}

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_iface() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*) return 1;;
    esac
    [ "${#1}" -le 15 ]
}

collect_wloc_ingress() {
    local section enabled iface
    section="$1"
    config_get_bool enabled "$section" enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get iface "$section" iface ''
    valid_iface "$iface" || {
        WLOC_RESOLVE_ERROR="invalid interface in enabled rule $section"
        return 0
    }
    case " $WLOC_INGRESS_INTERFACES " in
        *" $iface "*) ;;
        *) WLOC_INGRESS_INTERFACES="${WLOC_INGRESS_INTERFACES} $iface" ;;
    esac
}

sync_ingress_interfaces() {
    local interface interfaces
    nft list set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1 || {
        echo 'wloc: target ingress interface set is missing' >&2
        return 1
    }

    WLOC_RESOLVE_ERROR=''
    WLOC_INGRESS_INTERFACES=''
    config_load wloc || return 1
    config_foreach collect_wloc_ingress wifi
    [ -z "$WLOC_RESOLVE_ERROR" ] || {
        echo "wloc: $WLOC_RESOLVE_ERROR; interface set was not changed" >&2
        return 1
    }

    interfaces="$WLOC_INGRESS_INTERFACES"
    [ -n "$interfaces" ] || {
        echo 'wloc: no enabled ingress interfaces are configured' >&2
        return 1
    }

    {
        printf 'flush set %s %s %s\n' "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET"
        for interface in $interfaces; do
            printf 'add element %s %s %s { "%s" }\n' \
                "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" "$interface"
        done
    } | nft -f - || {
        echo 'wloc: unable to refresh ingress set; custom rules were left unchanged' >&2
        return 1
    }
}

reconcile() {
    local port
    port="$1"
    valid_port "$port" || {
        echo 'wloc: listen port must be between 1 and 65535 for the transparent proxy' >&2
        return 1
    }
    routing_ensure_current || {
        printf '%s\n' "wloc: ${routing_error:-unable to ensure TPROXY policy routing}" >&2
        return 1
    }
    sync_ingress_interfaces || {
        echo 'wloc: ingress-set reconciliation failed' >&2
        return 1
    }
}

if [ "${WLOC_RULES_SOURCE:-0}" -ne 1 ]; then
    case "${1:-}" in
        reconcile)
            port="${2:-}"
            reconcile "$port"
            ;;
        cleanup) cleanup;;
        reset) reset;;
        *) echo 'usage: rules.sh {reconcile PORT|cleanup|reset}' >&2; exit 2;;
    esac
fi
