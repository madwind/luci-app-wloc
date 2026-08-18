#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT"

build_scripts=(scripts/build-openwrt-*.sh)
if [ "${#build_scripts[@]}" -ne 1 ] || [ ! -f "${build_scripts[0]}" ]; then
	echo 'expected exactly one versioned OpenWrt build script' >&2
	exit 1
fi

current="$(awk -F= '$1 == "VERSION" { print $2; exit }' "${build_scripts[0]}")"
[ -n "$current" ] || { echo 'OpenWrt VERSION is missing' >&2; exit 1; }

series="${OPENWRT_SERIES:-${current%.*}}"
latest="$({
	git ls-remote --refs --tags https://github.com/openwrt/openwrt.git "v${series}.*"
} | awk '{ sub("refs/tags/v", "", $2); print $2 }' \
	| grep -E "^${series//./\\.}\\.[0-9]+$" \
	| sort -V \
	| tail -n 1)"
[ -n "$latest" ] || { echo "no stable OpenWrt ${series}.x tag found" >&2; exit 1; }

update_available=false
[ "$current" = "$latest" ] || update_available=true

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		printf 'current=%s\n' "$current"
		printf 'latest=%s\n' "$latest"
		printf 'update_available=%s\n' "$update_available"
	} >> "$GITHUB_OUTPUT"
fi

printf 'OpenWrt current=%s latest=%s update_available=%s\n' \
	"$current" "$latest" "$update_available"
