#!/bin/sh
set -eu

API='https://api.github.com/repos/madwind/luci-app-wloc'
PACKAGE_NAME='luci-app-wloc'
TMP="/tmp/wloc-install.$$"
RELEASE="$TMP/release.json"
COMPACT="$TMP/release.compact.json"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

command -v apk >/dev/null 2>&1 || die 'apk is required (OpenWrt 25.12+)'
command -v wget >/dev/null 2>&1 || die 'wget is required'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'

ARCH="$(apk --print-arch 2>/dev/null || true)"
case "$ARCH" in
    aarch64_cortex-a53) TARGET='mediatek-filogic' ;;
    aarch64_generic) TARGET='rockchip-armv8' ;;
    x86_64) TARGET='x86-64' ;;
    *) die "unsupported package architecture: ${ARCH:-unknown}" ;;
esac

mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

printf 'Downloading WLOC release metadata...\n'
wget -O "$RELEASE" "$API/releases/latest" || die 'failed to download release metadata'

tr -d ' \t\r\n' < "$RELEASE" > "$COMPACT" || die 'failed to parse release metadata'

TAG="$(sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' "$COMPACT")"
ASSET_LINE="$(
    sed 's#{"url":"https://api.github.com/repos/madwind/luci-app-wloc/releases/assets/#\
&#g' "$COMPACT" |
        grep "\"name\":\"luci-app-wloc-[^\"]*-${TARGET}\\.apk\"" |
        head -n 1
)"

[ -n "$ASSET_LINE" ] || die "release APK asset not found for $TARGET"

ASSET_URL="$(printf '%s\n' "$ASSET_LINE" | sed -n 's#^{"url":"\([^"]*\)".*#\1#p')"
ASSET="$(printf '%s\n' "$ASSET_LINE" | sed -n 's#.*"name":"\([^"]*\.apk\)".*#\1#p')"
SHA256="$(printf '%s\n' "$ASSET_LINE" | sed -n 's#.*"digest":"sha256:\([0-9A-Fa-f]*\)".*#\1#p' | tr 'A-F' 'a-f')"
VERSION="${TAG#v}"

[ -n "$TAG" ] || die 'missing release tag'
[ -n "$VERSION" ] || die 'missing release version'
[ -n "$ASSET_URL" ] || die 'missing release asset URL'
[ -n "$ASSET" ] || die 'missing release asset name'
[ -n "$SHA256" ] || die 'missing release asset SHA256'

case "$TAG" in *[!A-Za-z0-9._+-]*) die 'invalid release tag' ;; esac
case "$ASSET" in luci-app-wloc-*-$TARGET.apk) ;; *) die 'invalid package asset' ;; esac
case "$SHA256" in *[!0-9a-f]*) die 'invalid SHA256' ;; esac
[ "${#SHA256}" -eq 64 ] || die 'invalid SHA256 length'

case "$ASSET_URL" in
    "$API/releases/assets/"*) ;;
    *) die 'invalid release asset URL' ;;
esac
ASSET_ID="${ASSET_URL##*/}"
case "$ASSET_ID" in ''|*[!0-9]*) die 'invalid release asset ID' ;; esac

PACKAGE="$TMP/$ASSET"

printf 'Downloading WLOC %s for %s...\n' "$VERSION" "$TARGET"
wget --header='Accept: application/octet-stream' -O "$PACKAGE" "$ASSET_URL" || die 'package download failed'

ACTUAL="$(sha256sum "$PACKAGE" | awk '{ print $1 }')"
[ "$ACTUAL" = "$SHA256" ] || die 'SHA256 verification failed'

printf 'Updating package indexes...\n'
apk update || die 'apk update failed'

if apk info -e "$PACKAGE_NAME" >/dev/null 2>&1; then
    printf 'Upgrading %s...\n' "$ASSET"
    apk add --allow-untrusted --upgrade "$PACKAGE" || die 'package upgrade failed'
else
    printf 'Installing %s...\n' "$ASSET"
    apk add --allow-untrusted "$PACKAGE" || die 'package installation failed'
fi

printf '[OK] WLOC %s installed successfully.\n' "$VERSION"
