#!/bin/sh

FIREWALL=${WLOC_FIREWALL_PATH:-/etc/wloc/firewall.nft}
CRONTAB=/etc/crontabs/root
CRON_TAG=wloc-geoip-auto-weekly

uci -q delete wloc.main.geoip_file >/dev/null 2>&1 || true
uci -q delete wloc.main.geoip_url >/dev/null 2>&1 || true
uci -q delete wloc.main.geoip_auto_update >/dev/null 2>&1 || true
uci -q commit wloc >/dev/null 2>&1 || true

migrate_firewall() {
    local temporary
    [ -f "$FIREWALL" ] || return 0
    grep -q '%geoip:' "$FIREWALL" 2>/dev/null || return 0
    temporary="$(mktemp "${FIREWALL}.migrate.XXXXXX")" || return 1
    if ! awk '
        {
            line = $0
            if ($0 ~ /(^|[;[:space:]])type[[:space:]]+ipv4_addr([;[:space:]]|$)/) family = 4
            else if ($0 ~ /(^|[;[:space:]])type[[:space:]]+ipv6_addr([;[:space:]]|$)/) family = 6

            if (family == 4)
                gsub(/%geoip:private%/, "0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4", line)
            else if (family == 6)
                gsub(/%geoip:private%/, "::/127, fc00::/7, fe80::/10, ff00::/8", line)

            gsub(/[[:space:]]*,[[:space:]]*%geoip:cn%/, "", line)
            gsub(/%geoip:cn%[[:space:]]*,[[:space:]]*/, "", line)
            gsub(/%geoip:cn%/, "", line)
            print line

            if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) family = 0
        }
    ' "$FIREWALL" >"$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    if ! chmod 0600 "$temporary" || ! mv -f "$temporary" "$FIREWALL"; then
        rm -f "$temporary"
        return 1
    fi
    if grep -q '%geoip:' "$FIREWALL" 2>/dev/null; then
        logger -t wloc 'legacy custom GeoIP macro remains in /etc/wloc/firewall.nft; edit it before applying the rules' 2>/dev/null || true
    fi
}

migrate_firewall || exit 1

if [ -f "$CRONTAB" ] && grep -q "$CRON_TAG" "$CRONTAB" 2>/dev/null; then
    sed -i "/$CRON_TAG/d" "$CRONTAB" || true
    if pidof crond >/dev/null 2>&1; then
        /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
fi

rm -f /var/run/wloc/firewall.applied.source.nft \
    /var/run/wloc/firewall.warnings \
    /var/run/wloc/firewall.recovering \
    /var/run/wloc/firewall.runtime-warning

exit 0
