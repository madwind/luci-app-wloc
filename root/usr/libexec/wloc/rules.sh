#!/bin/sh
# Fixed ingress-interface set and IPv4 TPROXY policy-routing lifecycle.

set -eu

# OpenWrt's helper reads these variables directly. Initialize them before
# sourcing /lib/functions.sh so strict shell mode remains safe at runtime.
IPKG_INSTROOT=${IPKG_INSTROOT:-}
CONFIG_LIST_STATE=${CONFIG_LIST_STATE:-}
NO_CALLBACK=${NO_CALLBACK:-}
. /lib/functions.sh

INGRESS_FAMILY=bridge
INGRESS_TABLE=wloc
INGRESS_SET=target_ingress_interfaces
TPROXY_MARK=0x40000000
TPROXY_MASK=0x40000000
TPROXY_TABLE=201
TPROXY_PRIORITY=32764

clear_ingress_interfaces() {
    if nft list set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1; then
        nft flush set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1 || return 1
    fi
}

policy_rule_exists() {
    ip -4 rule show 2>/dev/null | grep -Eq \
        "fwmark ${TPROXY_MARK}/${TPROXY_MASK}.*lookup ${TPROXY_TABLE}"
}

ensure_policy_routing() {
    command -v ip >/dev/null 2>&1 || {
        echo 'wloc: ip-full is required for transparent proxy routing' >&2
        return 1
    }
    ip -4 route replace local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" || {
        echo 'wloc: unable to install the TPROXY local route' >&2
        return 1
    }
    if ! policy_rule_exists; then
        ip -4 rule add priority "$TPROXY_PRIORITY" \
            fwmark "$TPROXY_MARK/$TPROXY_MASK" lookup "$TPROXY_TABLE" || {
            echo 'wloc: unable to install the TPROXY policy rule' >&2
            return 1
        }
    fi
}

clear_policy_routing() {
    local rc=0
    while ip -4 rule del priority "$TPROXY_PRIORITY" \
        fwmark "$TPROXY_MARK/$TPROXY_MASK" lookup "$TPROXY_TABLE" >/dev/null 2>&1; do
        :
    done
    ip -4 route flush table "$TPROXY_TABLE" >/dev/null 2>&1 || true
    return "$rc"
}

cleanup() {
    local rc=0
    clear_ingress_interfaces || rc=1
    clear_policy_routing || rc=1
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
    ensure_policy_routing || return 1
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
        *) echo 'usage: rules.sh {reconcile PORT|cleanup}' >&2; exit 2;;
    esac
fi
