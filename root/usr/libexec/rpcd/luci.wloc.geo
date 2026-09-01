#!/bin/sh

GEO_UPDATE=${WLOC_GEO_UPDATE_PATH:-/usr/libexec/wloc/geo-update.sh}

case "$1" in
list)
    printf '%s\n' '{"status":{},"check":{},"update":{},"stop":{}}'
    ;;
call)
    case "$2" in
        status) exec "$GEO_UPDATE" status;;
        check) exec "$GEO_UPDATE" check;;
        update) exec "$GEO_UPDATE" start;;
        stop) exec "$GEO_UPDATE" stop;;
        *) printf '%s\n' '{"ok":false,"error":"unknown method"}'; exit 1;;
    esac
    ;;
*) exit 1;;
esac
