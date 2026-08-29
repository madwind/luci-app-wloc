#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../version.env
. "$PROJECT/version.env"

VERSION=25.12.5
RUST_TOOLCHAIN=1.89.0
BUILD_PROFILE="${1:-filogic}"

case "$BUILD_PROFILE" in
    filogic)
        TARGET=mediatek
        SUBTARGET=filogic
        SDK_SHA256=ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25
        RUST_TARGET=aarch64-unknown-linux-musl
        READELF_NAME=aarch64-openwrt-linux-musl-readelf
        FILE_ARCH_PATTERN='ARM aarch64'
        ELF_MACHINE_PATTERN='Machine:.*AArch64'
        ELF_INTERPRETER=/lib/ld-musl-aarch64.so.1
        APK_ARCH=aarch64_cortex-a53
        TARGET_MK_PATTERN='^SUBTARGET:=filogic$'
        ;;
    x86_64)
        TARGET=x86
        SUBTARGET=64
        SDK_SHA256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c
        RUST_TARGET=x86_64-unknown-linux-musl
        READELF_NAME=x86_64-openwrt-linux-musl-readelf
        FILE_ARCH_PATTERN='x86-64'
        ELF_MACHINE_PATTERN='Machine:.*X86-64'
        ELF_INTERPRETER=/lib/ld-musl-x86_64.so.1
        APK_ARCH=x86_64
        TARGET_MK_PATTERN='^ARCH:=x86_64$'
        ;;
    *)
        echo "usage: $0 [filogic|x86_64]" >&2
        exit 2
        ;;
esac

SDK_FILE="openwrt-sdk-${VERSION}-${TARGET}-${SUBTARGET}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
SDK_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${SDK_FILE}"
ZSTD_VERSION=1.5.7
ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

CACHE_ROOT="${OPENWRT_CACHE_ROOT:-$PROJECT/.build/openwrt-${VERSION}-${BUILD_PROFILE}}"
if [ -n "${OPENWRT_BUILD_ROOT:-}" ]; then
    BUILD_ROOT="$OPENWRT_BUILD_ROOT"
elif [ "$(stat -f -c %T "$PROJECT")" = v9fs ]; then
    # OpenWrt refuses case-insensitive Windows/WSL mounts. Keep sources and
    # downloads in the workspace, but compile on WSL's case-sensitive ext4.
    BUILD_ROOT="$HOME/.cache/luci-app-wloc/openwrt-${VERSION}-${BUILD_PROFILE}"
else
    BUILD_ROOT="$CACHE_ROOT"
fi
DOWNLOAD_DIR="$CACHE_ROOT/downloads"
EXTRACT_DIR="$BUILD_ROOT/sdk"
DIST_DIR="$PROJECT/dist/$BUILD_PROFILE"
ARCHIVE="$DOWNLOAD_DIR/$SDK_FILE"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing build command: $1" >&2; exit 1; }; }
for command in bash curl sha256sum tar make git file readelf find sed grep awk dd wc nproc stat mktemp chmod; do need "$command"; done
[ "$(uname -m)" = x86_64 ] || { echo 'the official SDK host requires Linux x86_64' >&2; exit 1; }

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$DIST_DIR"
if ! command -v zstd >/dev/null 2>&1; then
    ZSTD_PREFIX="$CACHE_ROOT/tools/zstd-${ZSTD_VERSION}"
    ZSTD_ARCHIVE="$DOWNLOAD_DIR/zstd-${ZSTD_VERSION}.tar.gz"
    if [ ! -x "$ZSTD_PREFIX/bin/zstd" ]; then
        [ -f "$ZSTD_ARCHIVE" ] || curl --fail --location --retry 3 --output "$ZSTD_ARCHIVE" \
            "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
        printf '%s  %s\n' "$ZSTD_SHA256" "$ZSTD_ARCHIVE" | sha256sum --check --status \
            || { echo 'zstd bootstrap checksum mismatch' >&2; exit 1; }
        mkdir -p "$ZSTD_PREFIX/source" "$ZSTD_PREFIX/bin"
        tar -xzf "$ZSTD_ARCHIVE" -C "$ZSTD_PREFIX/source" --strip-components=1
        make -C "$ZSTD_PREFIX/source" -j"$(nproc)" zstd-release
        cp "$ZSTD_PREFIX/source/programs/zstd" "$ZSTD_PREFIX/bin/"
    fi
    export PATH="$ZSTD_PREFIX/bin:$PATH"
fi
need zstd
if [ ! -f "$ARCHIVE" ]; then
    echo "Downloading $SDK_FILE"
    curl --fail --location --retry 3 --output "$ARCHIVE.part" "$SDK_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' "$SDK_SHA256" "$ARCHIVE" | sha256sum --check --status \
    || { echo 'SDK checksum mismatch' >&2; exit 1; }

SDK_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d -name "openwrt-sdk-${VERSION}-*" -print -quit)"
if [ -z "$SDK_DIR" ]; then
    echo 'Extracting SDK'
    tar --use-compress-program='zstd -d' -xf "$ARCHIVE" -C "$EXTRACT_DIR"
    SDK_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d -name "openwrt-sdk-${VERSION}-*" -print -quit)"
fi
[ -n "$SDK_DIR" ] && [ -d "$SDK_DIR" ] || { echo 'SDK extraction failed' >&2; exit 1; }
grep -Rqs "${VERSION}" "$SDK_DIR/include/version.mk" "$SDK_DIR/version.buildinfo" 2>/dev/null \
    || { echo "SDK is not OpenWrt $VERSION" >&2; exit 1; }
case "$(basename "$SDK_DIR")" in *-"${TARGET}"-"${SUBTARGET}"_*) ;; *) echo "SDK target is not ${TARGET}/${SUBTARGET}" >&2; exit 1;; esac
grep -Eqs "$TARGET_MK_PATTERN" "$SDK_DIR/target/linux/$TARGET/$SUBTARGET/target.mk" \
    || { echo "SDK does not contain the ${TARGET}/${SUBTARGET} subtarget" >&2; exit 1; }

if ! command -v rustup >/dev/null 2>&1; then
    echo "Installing rustup in the current Linux user account"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
    export PATH="$HOME/.cargo/bin:$PATH"
fi
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET"
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
(cd "$PROJECT/src/wloc-rs" && cargo fetch --locked)

PACKAGE_DST="$SDK_DIR/package/luci-app-wloc"
case "$PACKAGE_DST" in "$SDK_DIR/package/"*) ;; *) echo 'unsafe package destination' >&2; exit 1;; esac
rm -rf "$PACKAGE_DST"
mkdir -p "$PACKAGE_DST"
cp "$PROJECT/Makefile" "$PROJECT/version.env" "$PROJECT/LICENSE" "$PROJECT/NOTICE" "$PACKAGE_DST/"
cp -a "$PROJECT/src" "$PROJECT/htdocs" "$PROJECT/root" "$PACKAGE_DST/"
[ -d "$PROJECT/po" ] && cp -a "$PROJECT/po" "$PACKAGE_DST/"

# WSL/DrvFs exposes files copied from a Windows worktree as 0777 even when
# Git records the executable bit precisely. Normalize the package source
# before OpenWrt's install step so APK modes are reproducible on Linux and
# WSL alike.
find "$PACKAGE_DST/root" -type d -exec chmod 0755 {} +
find "$PACKAGE_DST/root" -type f -exec chmod 0644 {} +
for executable in \
    etc/init.d/wloc \
    etc/uci-defaults/luci-app-wloc \
    usr/libexec/wloc/rules.sh \
    usr/libexec/wloc/ap-lib.sh \
    usr/libexec/wloc/wifi-schedule.sh \
    usr/libexec/rpcd/luci.wloc; do
    chmod 0755 "$PACKAGE_DST/root/$executable"
done

echo 'Installing LuCI package definitions'
(
    cd "$SDK_DIR"
    ./scripts/feeds update luci
    ./scripts/feeds install luci-base
)

touch "$SDK_DIR/.config"
sed -i '/CONFIG_PACKAGE_luci-app-wloc=/d' "$SDK_DIR/.config"
printf '%s\n' 'CONFIG_PACKAGE_luci-app-wloc=m' >>"$SDK_DIR/.config"

echo 'Preparing OpenWrt SDK configuration'
# OpenWrt 25.12's SDK prepare-tmpinfo target invokes the prerequisite target
# even with FORCE=1. This package does not use menuconfig/ncurses or unzip;
# stamp only that host check so the real compile remains authoritative.
mkdir -p "$SDK_DIR/staging_dir/host"
touch "$SDK_DIR/staging_dir/host/.prereq-build"
FORCE=1 make -C "$SDK_DIR" defconfig
grep -qs "CONFIG_TARGET_${TARGET}=y" "$SDK_DIR/.config" \
    && grep -qs "CONFIG_TARGET_${TARGET}_${SUBTARGET}=y" "$SDK_DIR/.config" \
    || { echo "generated SDK config is not ${TARGET}/${SUBTARGET}" >&2; exit 1; }
# A minimal SDK can remove an external package selection while resolving the
# image dependency graph. Restore this package after defconfig; its runtime
# dependencies remain declared in the generated APK metadata.
sed -i '/CONFIG_PACKAGE_luci-app-wloc=/d' "$SDK_DIR/.config"
printf '%s\n' 'CONFIG_PACKAGE_luci-app-wloc=m' >>"$SDK_DIR/.config"
grep -qs '^CONFIG_PACKAGE_luci-app-wloc=m$' "$SDK_DIR/.config" \
    || { echo 'luci-app-wloc is not selected in the SDK config' >&2; exit 1; }
echo 'Building native OpenWrt APK v3 package'
PACKAGE_VERSION="$WLOC_VERSION"
PACKAGE_RELEASE="$WLOC_RELEASE"
EXPECTED_APK="luci-app-wloc-${PACKAGE_VERSION}-r${PACKAGE_RELEASE}.apk"
mkdir -p "$SDK_DIR/bin"
find "$SDK_DIR/bin" -type f -name 'luci-app-wloc-*.apk' -delete
make -C "$SDK_DIR" CONFIG_PACKAGE_libc=y CONFIG_PACKAGE_libgcc=y \
    package/toolchain/compile -j"$(nproc)" V=sc
make -C "$SDK_DIR" CONFIG_PACKAGE_luci-app-wloc=m package/luci-app-wloc/clean
make -C "$SDK_DIR" CONFIG_PACKAGE_luci-app-wloc=m \
    package/luci-app-wloc/compile -j"$(nproc)" V=sc

APK="$(find "$SDK_DIR/bin" -type f -name "$EXPECTED_APK" -print -quit)"
[ -n "$APK" ] && [ -f "$APK" ] || { echo "OpenWrt build did not produce $EXPECTED_APK" >&2; exit 1; }
[ "$(find "$SDK_DIR/bin" -type f -name 'luci-app-wloc-*.apk' | wc -l)" -eq 1 ] \
    || { echo 'OpenWrt build produced ambiguous WLOC APK artifacts' >&2; exit 1; }
find "$DIST_DIR" -maxdepth 1 -type f \
    -name 'luci-app-wloc-*.apk*' -delete
cp "$APK" "$DIST_DIR/"
APK="$DIST_DIR/$(basename "$APK")"

READELF="$(find "$SDK_DIR/staging_dir" -type f -name "$READELF_NAME" -print -quit)"
[ -x "$READELF" ] || READELF=readelf
APK_TOOL="$(find "$SDK_DIR/staging_dir/host"* -type f -path '*/bin/apk' -print -quit)"
BIN="$(find "$SDK_DIR/build_dir" -path '*/.pkgdir/luci-app-wloc/usr/sbin/wlocd' -type f -print -quit)"
[ -n "$BIN" ] && [ -f "$BIN" ] || { echo 'built wlocd was not found' >&2; exit 1; }

echo 'Verifying ELF and package metadata'
file "$BIN" | tee "$DIST_DIR/wlocd.file.txt"
file "$BIN" | grep -q "$FILE_ARCH_PATTERN" || { echo "wlocd is not ${APK_ARCH}" >&2; exit 1; }
"$READELF" -h "$BIN" | tee "$DIST_DIR/wlocd.elf-header.txt"
"$READELF" -h "$BIN" | grep -q "$ELF_MACHINE_PATTERN" || { echo "ELF machine is not ${APK_ARCH}" >&2; exit 1; }
"$READELF" -l "$BIN" | tee "$DIST_DIR/wlocd.elf-program-headers.txt"
"$READELF" -l "$BIN" | grep -q "$ELF_INTERPRETER" || { echo 'ELF musl interpreter is incorrect' >&2; exit 1; }
if [ -n "$APK_TOOL" ] && [ -x "$APK_TOOL" ]; then
    "$APK_TOOL" adbdump "$APK" | tee "$DIST_DIR/apk-metadata.txt"
    grep -Eq "^[[:space:]]*arch: ${APK_ARCH}$" "$DIST_DIR/apk-metadata.txt" \
        || { echo "APK metadata does not identify ${APK_ARCH}" >&2; exit 1; }
    grep -Eq '^[[:space:]]*name: luci-app-wloc$' "$DIST_DIR/apk-metadata.txt" \
        || { echo 'APK metadata has the wrong package name' >&2; exit 1; }
    grep -Eq "^[[:space:]]*version: ${PACKAGE_VERSION}-r${PACKAGE_RELEASE}$" "$DIST_DIR/apk-metadata.txt" \
        || { echo 'APK metadata has the wrong package version' >&2; exit 1; }
    APK_EXTRACT_DIR="$(mktemp -d)"
    (
        cd "$APK_EXTRACT_DIR"
        "$APK_TOOL" --allow-untrusted extract "$APK"
    )
    find "$APK_EXTRACT_DIR" -type f -printf '%P\n' | LC_ALL=C sort \
        | tee "$DIST_DIR/apk-files.txt"
    if ! file "$APK_EXTRACT_DIR/usr/sbin/wlocd" | grep -q "$FILE_ARCH_PATTERN"; then
        rm -rf "$APK_EXTRACT_DIR"
        echo "APK contains a wlocd binary for the wrong architecture" >&2
        exit 1
    fi
    ELF_FILES="$(find "$APK_EXTRACT_DIR" -type f -exec file {} + | awk -F: '/ELF/{print $1}')"
    [ "$ELF_FILES" = "$APK_EXTRACT_DIR/usr/sbin/wlocd" ] \
        || { rm -rf "$APK_EXTRACT_DIR"; echo 'APK contains an unexpected ELF file' >&2; exit 1; }
    [ "$(stat -c '%a' "$APK_EXTRACT_DIR/usr/sbin/wlocd")" = 755 ] \
        || { rm -rf "$APK_EXTRACT_DIR"; echo 'wlocd mode is not 0755' >&2; exit 1; }
    # OpenWrt rstrip removes section headers and updates the ELF header before
    # packaging. Compare the executable LOAD segment after its first metadata
    # page, which covers the program code and read-only data without those edits.
    executable_load_hash() {
        local elf offset size
        elf="$1"
        set -- $("$READELF" -lW "$elf" | awk '$1 == "LOAD" && $7 == "R" && $8 == "E" { print $2, $5; exit }')
        [ "$#" -eq 2 ] || return 1
        offset=$((0 + $1 + 4096))
        size=$((0 + $2 - 4096))
        [ "$size" -gt 0 ] || return 1
        dd if="$elf" bs=1 skip="$offset" count="$size" status=none \
            | sha256sum | awk '{print $1}'
    }
    built_text_hash="$(executable_load_hash "$BIN")"
    packaged_text_hash="$(executable_load_hash "$APK_EXTRACT_DIR/usr/sbin/wlocd")"
    [ -n "$built_text_hash" ] && [ "$built_text_hash" = "$packaged_text_hash" ] \
        || { rm -rf "$APK_EXTRACT_DIR"; echo 'APK wlocd code does not match the binary built in this run' >&2; exit 1; }
    for executable in \
        etc/init.d/wloc \
        etc/uci-defaults/luci-app-wloc \
        usr/libexec/wloc/rules.sh \
        usr/libexec/wloc/ap-lib.sh \
        usr/libexec/wloc/wifi-schedule.sh \
        usr/libexec/rpcd/luci.wloc; do
        [ "$(stat -c '%a' "$APK_EXTRACT_DIR/$executable")" = 755 ] \
            || { rm -rf "$APK_EXTRACT_DIR"; echo "$executable mode is not 0755" >&2; exit 1; }
    done
    for data_file in \
        etc/config/wloc \
        lib/upgrade/keep.d/luci-app-wloc \
        usr/share/luci/menu.d/luci-app-wloc.json \
        usr/share/rpcd/acl.d/luci-app-wloc.json \
        usr/share/ucitrack/luci-app-wloc.json \
        www/luci-static/resources/view/wloc/main.js; do
        [ "$(stat -c '%a' "$APK_EXTRACT_DIR/$data_file")" = 644 ] \
            || { rm -rf "$APK_EXTRACT_DIR"; echo "$data_file mode is not 0644" >&2; exit 1; }
    done
    rm -rf "$APK_EXTRACT_DIR"
else
    echo 'SDK apk metadata tool not found' >&2
    exit 1
fi

# Host tests run in the dedicated WLOC / Host checks workflow. Keep the
# package build independent so a host-only test failure does not discard a
# successfully built APK.
(cd "$DIST_DIR" && sha256sum "$(basename "$APK")") | tee "$APK.sha256"
echo "READY: $APK"
