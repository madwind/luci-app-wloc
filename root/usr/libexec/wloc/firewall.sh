#!/bin/sh

CORE=${WLOC_FIREWALL_CORE_PATH:-/usr/libexec/wloc/firewall-core.sh}

if [ "${WLOC_FIREWALL_HELPER_SOURCE:-0}" -eq 1 ] 2>/dev/null; then
    . "$CORE"
    return 0
fi

exec "$CORE" "$@"
