#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${OPENWRT_SDK:?OPENWRT_SDK is not set to an OpenWrt SDK directory}"
TARGET="${OPENWRT_TARGET:?OPENWRT_TARGET is not set}"
SUBTARGET="${OPENWRT_SUBTARGET:?OPENWRT_SUBTARGET is not set}"
APK_ARCH="${WLOC_APK_ARCH:?WLOC_APK_ARCH is not set}"
ELF_MACHINE="${WLOC_ELF_MACHINE:?WLOC_ELF_MACHINE is not set}"
ELF_INTERPRETER="${WLOC_ELF_INTERPRETER:?WLOC_ELF_INTERPRETER is not set}"
PACKAGE_NAME=luci-app-wloc

# shellcheck disable=SC1091
source "$PROJECT/version.env"
if [[ ! "$WLOC_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$WLOC_RELEASE" =~ ^[0-9]+$ ]]; then
    echo "Invalid WLOC_VERSION or WLOC_RELEASE in version.env: $WLOC_VERSION-r$WLOC_RELEASE" >&2
    exit 1
fi
PACKAGE_VERSION="$WLOC_VERSION-r$WLOC_RELEASE"

test -d "$SDK"
test -x "$SDK/staging_dir/host/bin/apk"
test -f "$SDK/feeds/luci/luci.mk"
command -v cargo >/dev/null
command -v readelf >/dev/null

PACKAGE_DIR="$SDK/package/$PACKAGE_NAME"
if [[ -e "$PACKAGE_DIR" ]]; then
    echo "Refusing to overwrite an existing SDK package directory: $PACKAGE_DIR" >&2
    exit 1
fi

OUT_DIR="$PROJECT/dist/$TARGET/$SUBTARGET"
OUT="$OUT_DIR/$PACKAGE_NAME-$PACKAGE_VERSION.apk"
mkdir -p "$OUT_DIR"

if [[ -d "$SDK/bin" ]]; then
    find "$SDK/bin" -type f -name 'luci-app-wloc-*.apk' -delete
fi

EXTRACT_DIR=""
cleanup() {
    rm -rf "$PACKAGE_DIR"
    if [[ -n "$EXTRACT_DIR" ]]; then
        rm -rf "$EXTRACT_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$PACKAGE_DIR/src/wloc-rs"
cp "$PROJECT/Makefile" "$PROJECT/version.env" "$PROJECT/LICENSE" "$PROJECT/NOTICE" "$PACKAGE_DIR/"
cp "$PROJECT/src/Makefile" "$PACKAGE_DIR/src/Makefile"
cp "$PROJECT/src/wloc-rs/Cargo.toml" "$PROJECT/src/wloc-rs/Cargo.lock" "$PACKAGE_DIR/src/wloc-rs/"
cp -a "$PROJECT/src/wloc-rs/src" "$PACKAGE_DIR/src/wloc-rs/"
cp -a "$PROJECT/root" "$PROJECT/htdocs" "$PACKAGE_DIR/"
if [[ -d "$PROJECT/po" ]]; then
    cp -a "$PROJECT/po" "$PACKAGE_DIR/"
fi

# Preserve executable bits from Git instead of maintaining a chmod whitelist.
while IFS= read -r -d '' source; do
    relative="${source#"$PROJECT/root/"}"
    copied="$PACKAGE_DIR/root/$relative"
    if [[ ! -x "$copied" ]]; then
        echo "Executable mode was not preserved for root/$relative" >&2
        exit 1
    fi
done < <(find "$PROJECT/root" -type f -perm -u+x -print0)

jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 1)"

printf 'Building OpenWrt target toolchain\n'
make -C "$SDK" \
    CONFIG_PACKAGE_libc=y \
    CONFIG_PACKAGE_libgcc=y \
    package/toolchain/compile \
    -j"$jobs" V=sc

printf 'Building %s\n' "$PACKAGE_VERSION"
make -C "$SDK" CONFIG_PACKAGE_$PACKAGE_NAME=m package/$PACKAGE_NAME/clean
make -C "$SDK" CONFIG_PACKAGE_$PACKAGE_NAME=m package/$PACKAGE_NAME/compile -j"$jobs" V=sc

mapfile -t matches < <(find "$SDK/bin" -type f -name "$PACKAGE_NAME-$PACKAGE_VERSION.apk" -print | sort)
mapfile -t packages < <(find "$SDK/bin" -type f -name "$PACKAGE_NAME-*.apk" -print | sort)
if (( ${#matches[@]} != 1 )); then
    echo "OpenWrt SDK did not produce exactly one $PACKAGE_NAME-$PACKAGE_VERSION.apk" >&2
    exit 1
fi
if (( ${#packages[@]} != 1 )); then
    echo "OpenWrt SDK produced ambiguous WLOC APK artifacts" >&2
    exit 1
fi
cp -f "${matches[0]}" "$OUT"

APK_TOOL="$SDK/staging_dir/host/bin/apk"
metadata="$($APK_TOOL adbdump "$OUT")"
grep -Eq "^[[:space:]]*arch: ${APK_ARCH}$" <<<"$metadata" || {
    echo "APK metadata does not identify $APK_ARCH" >&2
    exit 1
}
grep -Eq "^[[:space:]]*name: ${PACKAGE_NAME}$" <<<"$metadata" || {
    echo "APK metadata has the wrong package name" >&2
    exit 1
}
grep -Eq "^[[:space:]]*version: ${PACKAGE_VERSION}$" <<<"$metadata" || {
    echo "APK metadata has the wrong package version" >&2
    exit 1
}

EXTRACT_DIR="$(mktemp -d)"
(
    cd "$EXTRACT_DIR"
    "$APK_TOOL" --allow-untrusted extract "$OUT" >/dev/null
)

WLOCD="$EXTRACT_DIR/usr/sbin/wlocd"
test -x "$WLOCD"
readelf -h "$WLOCD" | grep -Eq "Machine:.*${ELF_MACHINE}" || {
    echo "wlocd ELF machine is not $ELF_MACHINE" >&2
    exit 1
}
readelf -l "$WLOCD" | grep -Fq "$ELF_INTERPRETER" || {
    echo "wlocd musl interpreter is incorrect" >&2
    exit 1
}

while IFS= read -r -d '' source; do
    relative="${source#"$PROJECT/root/"}"
    packaged="$EXTRACT_DIR/$relative"
    expected_mode="$(stat -c '%a' "$source")"
    actual_mode="$(stat -c '%a' "$packaged" 2>/dev/null || true)"
    if [[ "$actual_mode" != "$expected_mode" ]]; then
        echo "$relative mode is $actual_mode, expected $expected_mode" >&2
        exit 1
    fi
done < <(find "$PROJECT/root" -type f -perm -u+x -print0)

printf 'APK: %s\n' "$OUT"
