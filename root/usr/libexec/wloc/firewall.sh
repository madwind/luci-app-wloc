#!/bin/sh

# GeoIP-aware frontend around the original WLOC firewall transaction helper.

WLOC_FIREWALL_WRAPPER_SOURCED=${WLOC_FIREWALL_HELPER_SOURCE:-0}
WLOC_FIREWALL_HELPER_SOURCE=1
. "${WLOC_FIREWALL_CORE_PATH:-/usr/libexec/wloc/firewall-core.sh}"
WLOC_FIREWALL_HELPER_SOURCE=$WLOC_FIREWALL_WRAPPER_SOURCED

FIREWALL_GEO_COMPILER=${WLOC_FIREWALL_GEO_COMPILER:-/usr/libexec/wloc/firewall-geo.lua}
FIREWALL_SOURCE_RUNTIME=${WLOC_FIREWALL_SOURCE_RUNTIME:-/var/run/wloc/firewall.applied.source.nft}
FIREWALL_LAST_WARNINGS=${WLOC_FIREWALL_WARNINGS_PATH:-/var/run/wloc/firewall.warnings}
FIREWALL_RECOVERING_PATH=${WLOC_FIREWALL_RECOVERING_PATH:-/var/run/wloc/firewall.recovering}
FIREWALL_RUNTIME_WARNING_PATH=${WLOC_FIREWALL_RUNTIME_WARNING_PATH:-/var/run/wloc/firewall.runtime-warning}

firewall_frontend_store_file() {
    local source="$1" destination="$2" directory temporary
    directory="${destination%/*}"
    [ "$directory" = "$destination" ] && directory='.'
    mkdir -p "$directory" || return 1
    temporary="$(mktemp "${destination}.XXXXXX")" || return 1
    if ! cp "$source" "$temporary" || ! chmod 0600 "$temporary" || ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
}

firewall_frontend_action() {
    local action="$1" source="$2" compiled warnings detail rc
    [ -r "$source" ] || { printf '%s\n' 'nftables configuration file is not readable' >&2; return 1; }
    mkdir -p "$FIREWALL_RUNTIME_DIR" || return 1
    compiled="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-compiled.XXXXXX")" || return 1
    warnings="$(mktemp "$FIREWALL_RUNTIME_DIR/firewall-warnings.XXXXXX")" || { rm -f "$compiled"; return 1; }

    if ! detail="$(lua "$FIREWALL_GEO_COMPILER" compile "$source" "$compiled" "$warnings" 2>&1)"; then
        rm -f "$compiled" "$warnings"
        printf '%s\n' "${detail:-GeoIP macro compilation failed}" >&2
        return 1
    fi
    firewall_frontend_store_file "$warnings" "$FIREWALL_LAST_WARNINGS" || true

    case "$action" in
        validate)
            if firewall_validate_file "$compiled"; then rc=0; else rc=$?; fi
            ;;
        apply)
            if firewall_apply_file "$compiled"; then
                rc=0
                firewall_frontend_store_file "$source" "$FIREWALL_SOURCE_RUNTIME" || {
                    rm -f "$compiled" "$warnings"
                    printf '%s\n' 'unable to store the applied firewall source snapshot' >&2
                    return 1
                }
                printf '%s\n' "${FIREWALL_RUNTIME_RECOVERING:-0}" >"$FIREWALL_RECOVERING_PATH" 2>/dev/null || true
                printf '%s\n' "${FIREWALL_RUNTIME_WARNING:-}" >"$FIREWALL_RUNTIME_WARNING_PATH" 2>/dev/null || true
            else
                rc=$?
            fi
            ;;
        *) rc=2;;
    esac

    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "${firewall_error:-nftables operation failed}" >&2
    fi
    rm -f "$compiled" "$warnings"
    return "$rc"
}

if [ "$WLOC_FIREWALL_WRAPPER_SOURCED" -eq 1 ] 2>/dev/null; then
    return 0
fi

case "${1:-}" in
    validate|apply)
        firewall_frontend_action "$1" "${2:-}"
        ;;
    active)
        firewall_active || {
            printf '%s\n' "${firewall_error:-both WLOC nftables tables are not active}" >&2
            exit 1
        }
        printf '%s\n' "${FIREWALL_ACTIVE:-# No WLOC nftables tables are active.}"
        ;;
    remove-runtime)
        firewall_remove_runtime || {
            printf '%s\n' "${firewall_error:-failed to remove WLOC nftables tables}" >&2
            exit 1
        }
        rm -f "$FIREWALL_SOURCE_RUNTIME" "$FIREWALL_LAST_WARNINGS" \
            "$FIREWALL_RECOVERING_PATH" "$FIREWALL_RUNTIME_WARNING_PATH"
        ;;
    *)
        printf '%s\n' 'usage: firewall.sh {validate|apply|active} FILE | remove-runtime' >&2
        exit 2
        ;;
esac
