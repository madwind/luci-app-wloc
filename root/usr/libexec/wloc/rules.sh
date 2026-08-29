#!/bin/sh
# Dedicated fail-open interception lifecycle for OpenWrt WLOC.

set -eu

HOST_FAMILY=inet
HOST_TABLE=wloc
HOST_SET=apple_wloc_v4
INGRESS_FAMILY=bridge
INGRESS_TABLE=wloc
INGRESS_SET=target_ingress_interfaces
RULES_RUNTIME_DIR=${WLOC_RUNTIME_DIR:-/var/run/wloc}
STAMP=${WLOC_HOSTS_STAMP:-${RULES_RUNTIME_DIR}/hosts.refreshed}
DNS_ATTEMPT_STAMP=${WLOC_DNS_ATTEMPT_STAMP:-${RULES_RUNTIME_DIR}/hosts.attempted}
AP_LIB=${WLOC_AP_LIB_PATH:-/usr/libexec/wloc/ap-lib.sh}
HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'
HOST_TIMEOUT=15m
DNS_SAMPLES=1
DNS_REFRESH_SECONDS=300
DNS_RETRY_SECONDS=10
INGRESS_INTERFACE_TIMEOUT=120s

clear_ingress_interfaces() {
    if nft list set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1; then
        nft flush set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" >/dev/null 2>&1 || return 1
    fi
}

clear_host_set() {
    if nft list set "$HOST_FAMILY" "$HOST_TABLE" "$HOST_SET" >/dev/null 2>&1; then
        nft flush set "$HOST_FAMILY" "$HOST_TABLE" "$HOST_SET" >/dev/null 2>&1 || return 1
    fi
}

cleanup() {
    local rc=0
    clear_ingress_interfaces || rc=1
    clear_host_set || rc=1
    rm -f "$STAMP" "$DNS_ATTEMPT_STAMP" || rc=1
    return "$rc"
}

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4() {
    case "$1" in ''|*[!0-9.]*) return 1;; esac
    oldifs=$IFS; IFS=.; set -- $1; IFS=$oldifs
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] 2>/dev/null || return 1; done
}

host_set_has_elements() {
    printf '%s\n' "$1" | grep -Eq '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)'
}

resolve_hosts() {
    local now last attempt addresses host resolved_ip sample set_dump
    # A missing table or set is an intentional opt-out from DNS maintenance.
    set_dump="$(nft list set "$HOST_FAMILY" "$HOST_TABLE" "$HOST_SET" 2>/dev/null)" || return 0
    [ -d "${STAMP%/*}" ] || mkdir -p "${STAMP%/*}"
    now="$(date +%s)"
    last="$(cat "$STAMP" 2>/dev/null || echo 0)"
    [ $((now - last)) -ge "$DNS_REFRESH_SECONDS" ] || return 0
    attempt="$(cat "$DNS_ATTEMPT_STAMP" 2>/dev/null || echo 0)"
    [ $((now - attempt)) -ge "$DNS_RETRY_SECONDS" ] || return 0
    printf '%s\n' "$now" >"$DNS_ATTEMPT_STAMP"
    addresses=''
    for host in $HOSTS; do
        sample=0
        while [ "$sample" -lt "$DNS_SAMPLES" ]; do
            # BusyBox nslookup prints the DNS server as an Address before the
            # answer Name. Parse only Address lines in the answer section.
            for resolved_ip in $(nslookup "$host" 127.0.0.1 2>/dev/null \
                | sed -n '/^Name:[[:space:]]/,$ s/^Address[^:]*:[[:space:]]*\([0-9][0-9.]*\).*$/\1/p'); do
                valid_ipv4 "$resolved_ip" || continue
                case " $addresses " in
                    *" $resolved_ip "*) :;;
                    *) addresses="${addresses} ${resolved_ip}";;
                esac
            done
            sample=$((sample + 1))
        done
    done
    if [ -z "$addresses" ]; then
        if host_set_has_elements "$set_dump"; then
            # Keep known CDN addresses until their nftables timeout expires.
            return 0
        fi
        echo 'wloc: DNS resolution failed and the WLOC host set is empty' >&2
        return 1
    fi

    for resolved_ip in $addresses; do
        if nft get element "$HOST_FAMILY" "$HOST_TABLE" "$HOST_SET" "{ $resolved_ip }" >/dev/null 2>&1; then
            if ! nft -f - <<EOF
delete element $HOST_FAMILY $HOST_TABLE $HOST_SET { $resolved_ip }
add element $HOST_FAMILY $HOST_TABLE $HOST_SET { $resolved_ip timeout $HOST_TIMEOUT }
EOF
            then
                echo 'wloc: unable to refresh the WLOC host set' >&2
                return 1
            fi
        elif ! nft add element "$HOST_FAMILY" "$HOST_TABLE" "$HOST_SET" "{ $resolved_ip timeout $HOST_TIMEOUT }"; then
            echo 'wloc: unable to refresh the WLOC host set' >&2
            return 1
        fi
    done
    printf '%s\n' "$now" >"$STAMP" || return 1
}

load_ap_lib() {
    [ "${WLOC_AP_LIB_LOADED:-0}" -eq 1 ] || . "$AP_LIB"
}

collect_wloc_ingress() {
    local section enabled iface
    section="$1"
    config_get_bool enabled "$section" enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get iface "$section" iface ''
    [ -n "$iface" ] || {
        WLOC_RESOLVE_ERROR="interface is missing from enabled rule $section"
        return 0
    }
    if ! wloc_ap_find_section_by_ifname "$iface" >/dev/null; then
        WLOC_RESOLVE_ERROR="cannot resolve configured interface \"$iface\""
        return 0
    fi
    # The rule stores the fixed wifi-iface name. Use it directly so startup
    # does not need to scan runtime interfaces or expand a bridge.
    case " $WLOC_INGRESS_INTERFACES " in
        *" $iface "*) ;;
        *) WLOC_INGRESS_INTERFACES="${WLOC_INGRESS_INTERFACES} $iface" ;;
    esac
}

sync_ingress_interfaces() {
    local interface interfaces set_dump
    WLOC_RESOLVE_ERROR=''
    WLOC_INGRESS_INTERFACES=''
    # A missing table or set is an intentional opt-out from ingress maintenance.
    set_dump="$(nft list set "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" 2>/dev/null)" || return 0
    load_ap_lib || return 1
    config_load wloc || return 1
    config_foreach collect_wloc_ingress wifi
    [ -z "$WLOC_RESOLVE_ERROR" ] || {
        echo "wloc: $WLOC_RESOLVE_ERROR; interface set was not changed" >&2
        return 1
    }
    interfaces="$WLOC_INGRESS_INTERFACES"
    {
        printf 'flush set %s %s %s\n' "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET"
        for interface in $interfaces; do
            printf 'add element %s %s %s { "%s" timeout %s }\n' \
                "$INGRESS_FAMILY" "$INGRESS_TABLE" "$INGRESS_SET" "$interface" "$INGRESS_INTERFACE_TIMEOUT"
        done
    } | nft -f - || {
        echo 'wloc: unable to refresh ingress set; custom rules were left unchanged' >&2
        return 1
    }
}

reconcile() {
    local port
    port="$1"
    valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; return 1; }
    resolve_hosts || {
        echo 'wloc: host-set reconciliation failed' >&2
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
        *) echo 'usage: rules.sh {reconcile PORT|cleanup}' >&2; exit 2;;
    esac
fi
