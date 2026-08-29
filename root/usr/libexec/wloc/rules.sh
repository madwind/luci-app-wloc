#!/bin/sh
# Dedicated fail-open interception lifecycle for OpenWrt WLOC.

set -eu

TABLE=wloc
INGRESS_SET=target_ingress_interfaces
HOST_SET=apple_wloc_v4
# The firewall helper updates this snapshot only after nft succeeds, so DNS
# maintenance follows the active configuration rather than unsaved state.
RULES_RUNTIME_DIR=${WLOC_RUNTIME_DIR:-/var/run/wloc}
CUSTOM_FIREWALL=${WLOC_FIREWALL_RUNTIME:-${RULES_RUNTIME_DIR}/firewall.applied.nft}
PERSISTENT_FIREWALL=${WLOC_FIREWALL_PATH:-/etc/wloc/firewall.nft}
STAMP=${WLOC_HOSTS_STAMP:-${RULES_RUNTIME_DIR}/hosts.refreshed}
DNS_ATTEMPT_STAMP=${WLOC_DNS_ATTEMPT_STAMP:-${RULES_RUNTIME_DIR}/hosts.attempted}
AP_LIB=${WLOC_AP_LIB_PATH:-/usr/libexec/wloc/ap-lib.sh}
HOSTS='gs-loc.apple.com gs-loc-cn.apple.com'
HOST_TIMEOUT=15m
DNS_SAMPLES=1
DNS_REFRESH_SECONDS=300
DNS_RETRY_SECONDS=10
INGRESS_INTERFACE_TIMEOUT=120s

firewall_snapshot() {
    if [ -f "$CUSTOM_FIREWALL" ]; then
        printf '%s\n' "$CUSTOM_FIREWALL"
    elif [ -f "$PERSISTENT_FIREWALL" ]; then
        printf '%s\n' "$PERSISTENT_FIREWALL"
    fi
    return 0
}

declarative_set_targets() {
    local set_name snapshot
    set_name="$1"
    snapshot="$(firewall_snapshot)"
    [ -n "$snapshot" ] || return 0
    awk -v target_set="$set_name" '
        {
            line = $0
            sub(/#.*/, "", line)
            gsub(/[{};]/, "\n", line)
            count = split(line, statements, "\n")
            for (i = 1; i <= count; i++) {
                fields = split(statements[i], words, /[[:space:]]+/)
                first = 1
                while (first <= fields && words[first] == "") first++
                if (words[first] == "table" && words[first + 2] != "") {
                    family = words[first + 1]
                    table_name = words[first + 2]
                } else if (words[first] == "add" && words[first + 1] == "table" \
                    && words[first + 3] != "") {
                    family = words[first + 2]
                    table_name = words[first + 3]
                } else if (words[first] == "set" && words[first + 1] == target_set \
                    && family != "" && table_name != "") {
                    print family, table_name
                } else if (words[first] == "add" && words[first + 1] == "set" \
                    && words[first + 2] == target_set) {
                    print words[first + 3], words[first + 4]
                }
            }
        }
    ' "$snapshot" | awk '!seen[$0]++'
}

ingress_set_targets() {
    declarative_set_targets "$INGRESS_SET"
}

clear_ingress_interfaces() {
    local family table_name set_dump rc=0
    while read -r family table_name; do
        [ -n "$family" ] || continue
        if ! set_dump="$(nft list set "$family" "$table_name" "$INGRESS_SET" 2>/dev/null)"; then
            continue
        fi
        if ! ingress_set_compatible "$set_dump"; then
            echo "wloc: optional ingress set $family/$table_name/$INGRESS_SET has an incompatible type" >&2
            rc=1
            continue
        fi
        nft flush set "$family" "$table_name" "$INGRESS_SET" >/dev/null 2>&1 || rc=1
    done <<EOF
$(ingress_set_targets)
EOF
    return "$rc"
}

clear_host_sets() {
    local family table_name set_dump rc=0

    while read -r family table_name; do
        [ -n "$family" ] || continue

        if ! set_dump="$(
            nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null
        )"; then
            continue
        fi

        if ! host_set_compatible "$set_dump"; then
            echo "wloc: optional host set $family/$table_name/$HOST_SET has an incompatible type" >&2
            rc=1
            continue
        fi

        nft flush set "$family" "$table_name" "$HOST_SET" >/dev/null 2>&1 || rc=1
    done <<EOF
$(host_set_targets)
EOF

    return "$rc"
}

cleanup() {
    local rc=0
    clear_ingress_interfaces || rc=1
    clear_host_sets || rc=1
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

host_set_targets() {
    local snapshot

    snapshot="$(firewall_snapshot)"

    {
        if [ -z "$snapshot" ]; then
            printf 'inet %s\n' "$TABLE"
        fi
        declarative_set_targets "$HOST_SET"
    } | awk '!seen[$0]++'
}

host_set_available() {
    local family table_name
    while read -r family table_name; do
        [ -n "$family" ] || continue
        if nft list set "$family" "$table_name" "$HOST_SET" >/dev/null 2>&1; then
            return 0
        fi
    done <<EOF
$(host_set_targets)
EOF
    return 1
}

host_set_compatible() {
    printf '%s\n' "$1" | grep -q 'type ipv4_addr' &&
        printf '%s\n' "$1" | grep -Eq 'flags timeout|^[[:space:]]*timeout[[:space:]]'
}

host_set_has_elements() {
    printf '%s\n' "$1" | awk '
        /elements[[:space:]]*=/ { in_elements = 1 }
        in_elements && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ { found = 1 }
        in_elements && /}/ {
            if (found) exit 0
            in_elements = 0
        }
        END { exit(found ? 0 : 1) }
    '
}

resolve_hosts() {
    local now last attempt addresses host resolved_ip sample family table_name set_dump
    local compatible_targets has_elements maintenance_failed
    # Do not perform DNS work when neither the automatic table nor a custom
    # table currently exposes the managed set.
    host_set_available || return 0
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
        compatible_targets=0
        has_elements=0
        maintenance_failed=0
        while read -r family table_name; do
            [ -n "$family" ] || continue
            if ! set_dump="$(nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null)"; then
                maintenance_failed=1
                continue
            fi
            if ! host_set_compatible "$set_dump"; then
                maintenance_failed=1
                continue
            fi
            compatible_targets=1
            host_set_has_elements "$set_dump" && has_elements=1
        done <<EOF
$(host_set_targets)
EOF
        if [ "$maintenance_failed" -eq 1 ] || [ "$compatible_targets" -eq 0 ]; then
            echo 'wloc: DNS resolution failed and the host set could not be verified' >&2
            return 1
        fi
        if [ "$has_elements" -eq 1 ]; then
            # Keep known CDN addresses until their nftables timeout expires.
            return 0
        fi
        echo 'wloc: DNS resolution failed and the WLOC host set is empty' >&2
        return 1
    fi
    compatible_targets=0
    maintenance_failed=0
    while read -r family table_name; do
        [ -n "$family" ] || continue
        if ! set_dump="$(nft list set "$family" "$table_name" "$HOST_SET" 2>/dev/null)"; then
            maintenance_failed=1
            continue
        fi
        if ! host_set_compatible "$set_dump"; then
            maintenance_failed=1
            continue
        fi
        compatible_targets=1
        for resolved_ip in $addresses; do
            if nft get element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip }" >/dev/null 2>&1; then
                if ! nft -f - <<EOF
delete element $family $table_name $HOST_SET { $resolved_ip }
add element $family $table_name $HOST_SET { $resolved_ip timeout $HOST_TIMEOUT }
EOF
                then
                    maintenance_failed=1
                fi
            elif ! nft add element "$family" "$table_name" "$HOST_SET" "{ $resolved_ip timeout $HOST_TIMEOUT }"; then
                maintenance_failed=1
            fi
        done
    done <<EOF
$(host_set_targets)
EOF
    [ "$compatible_targets" -gt 0 ] || maintenance_failed=1
    [ "$maintenance_failed" -eq 0 ] || {
        echo 'wloc: unable to refresh the WLOC host set' >&2
        return 1
    }
    printf '%s\n' "$now" >"$STAMP" || return 1
}

refresh_hosts() {
    rm -f "$STAMP" "$DNS_ATTEMPT_STAMP"
    resolve_hosts
}

apply_rules() {
    local port
    port="$1"
    valid_port "$port" || { echo 'wloc: invalid proxy port' >&2; return 1; }
    refresh_hosts
}

valid_ifname() {
    case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
    [ "${#1}" -le 15 ]
}

ingress_set_compatible() {
    printf '%s\n' "$1" | awk '
        {
            line = $0
            sub(/^[[:space:]]*type[[:space:]]+/, "", line)
            gsub(/[[:space:];]+$/, "", line)
            if (line == "ifname") type_ok = 1

            line = $0
            sub(/^[[:space:]]*flags[[:space:]]+/, "", line)
            if (line != $0) {
                count = split(line, flags, /[[:space:];]+/)
                for (i = 1; i <= count; i++) {
                    if (flags[i] == "timeout") timeout_ok = 1
                }
            }
            if ($0 ~ /^[[:space:]]*timeout([[:space:];]|$)/) timeout_ok = 1
        }
        END { exit (type_ok && timeout_ok) ? 0 : 1 }
    '
}

load_ap_lib() {
    [ "${WLOC_AP_LIB_LOADED:-0}" -eq 1 ] || . "$AP_LIB"
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
    valid_ifname "$iface" || {
        WLOC_RESOLVE_ERROR="invalid configured interface \"$iface\""
        return 0
    }
    case " $WLOC_INGRESS_INTERFACES " in
        *" $iface "*) ;;
        *) WLOC_INGRESS_INTERFACES="${WLOC_INGRESS_INTERFACES} $iface" ;;
    esac
}

sync_ingress_interfaces() {
    local interface interfaces family table_name set_dump targets valid_targets
    WLOC_RESOLVE_ERROR=''
    WLOC_INGRESS_INTERFACES=''
    targets="$(ingress_set_targets)"
    # A custom ruleset may not use WLOC's optional interface set at all.
    [ -n "$targets" ] || return 0
    valid_targets=''
    while read -r family table_name; do
        [ -n "$family" ] || continue
        if ! set_dump="$(nft list set "$family" "$table_name" "$INGRESS_SET" 2>/dev/null)"; then
            # The table may have been removed outside WLOC after the snapshot
            # was applied. Treat that optional target as absent and continue.
            continue
        fi
        if ! ingress_set_compatible "$set_dump"; then
            echo "wloc: optional ingress set $family/$table_name/$INGRESS_SET has an incompatible type" >&2
            return 1
        fi
        if [ -n "$valid_targets" ]; then
            valid_targets="$valid_targets
$family $table_name"
        else
            valid_targets="$family $table_name"
        fi
    done <<EOF
$targets
EOF
    [ -n "$valid_targets" ] || return 0
    load_ap_lib || return 1
    config_load wloc || return 1
    config_foreach collect_wloc_ingress wifi
    [ -z "$WLOC_RESOLVE_ERROR" ] || {
        echo "wloc: $WLOC_RESOLVE_ERROR; interface set was not changed" >&2
        return 1
    }
    interfaces="$WLOC_INGRESS_INTERFACES"
    {
        while read -r family table_name; do
            [ -n "$family" ] || continue
            printf 'flush set %s %s %s\n' "$family" "$table_name" "$INGRESS_SET"
            for interface in $interfaces; do
                printf 'add element %s %s %s { "%s" timeout %s }\n' \
                "$family" "$table_name" "$INGRESS_SET" "$interface" "$INGRESS_INTERFACE_TIMEOUT"
            done
        done <<EOF
$valid_targets
EOF
    } | nft -f - || {
        echo 'wloc: unable to refresh ingress sets; custom rules were left unchanged' >&2
        return 1
    }
}

if [ "${WLOC_RULES_SOURCE:-0}" -ne 1 ]; then
    case "${1:-}" in
        apply)
            port="${2:-}"
            apply_rules "$port"
            ;;
        reconcile)
            port="${2:-}"
            reconcile "$port"
            ;;
        cleanup) cleanup;;
        status)
            nft list table inet "$TABLE" 2>/dev/null
            ;;
        resolve-hosts)
            resolve_hosts
            ;;
        refresh-hosts)
            refresh_hosts
            ;;
        *) echo 'usage: rules.sh {apply PORT|reconcile PORT|cleanup|status|resolve-hosts|refresh-hosts}' >&2; exit 2;;
    esac
fi
