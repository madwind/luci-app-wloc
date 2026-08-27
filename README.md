# luci-app-wloc

`luci-app-wloc` is a small OpenWrt package that assigns a virtual Apple WLOC
location baseline to each selected access point and follows each real movement
delta from that fixed baseline. It includes a native Rust service, isolated
nftables rules, UCI/procd integration, RPC support, and a LuCI interface.

![WLOC LuCI dashboard](docs/images/wloc-dashboard.png)

Each entry selects one AP by BSSID and assigns one location and optional
outbound proxy to every device connected through that AP. Entries are evaluated
in configuration order; the first matching AP wins. Requests from an AP without
a matching entry pass through unchanged. Use this package only on devices you
own or are authorized to test.

Each AP can also be given a daily disable window in router local
time. During the window, matching configured AP interfaces receive a temporary
runtime `disabled` override and are reloaded; the original wireless UCI values
are restored when the window ends and are never committed by WLOC. Equal start
and end times mean all day, and an end time earlier than the start crosses
midnight. The window targets only the selected `wifi-iface`, resolved by its
section, explicit BSSID/MAC, or its live AP interface. It never falls back to
disabling the entire radio when that mapping is unavailable.

The nftables rules put selected AP interfaces in a hostapd interface set, then
match the resolved IPv4 addresses of both Apple WLOC hostnames and TCP/443. They
do not capture the whole LAN bridge.
WLOC uses the prerouting priority configured in its nftables table. The default
configuration uses `mangle - 2` (`-152`). At runtime, WLOC scans other
IPv4-capable prerouting chains for reachable `REDIRECT` or `TPROXY` paths and
compares their priorities with the active WLOC chain. WLOC no longer rewrites
its own priority automatically. Conflicts or unparseable priorities are
reported through runtime state, system logs, and LuCI.

WLOC does not install a TPROXY stage, policy route, or OUTPUT hook. The client
connection is redirected to WLOC first. After WLOC handles it, the daemon's
upstream socket is ordinary router-local output, so any other proxy—including
a transparent proxy—with a matching OUTPUT policy can process it normally.

## Supported targets

- Xiaomi AX3000T and other OpenWrt 25.12.5 MediaTek Filogic devices
  (`aarch64_cortex-a53`)
- OpenWrt 25.12.5 x86/64 devices (`x86_64`)

## Build

Run the build on Linux x86_64. WSL2 is also supported.

Package versions are configured only in `version.env`. Update
`WLOC_VERSION` for an application release, and `WLOC_RELEASE` when rebuilding
the same application version with packaging-only changes.

```sh
# MediaTek Filogic
bash ./scripts/build-openwrt-25.12.5.sh filogic

# OpenWrt x86/64
bash ./scripts/build-openwrt-25.12.5.sh x86_64
```

The script downloads and verifies the official OpenWrt SDK, builds the native
musl binary and APK package, validates the result, and writes artifacts to
`dist/filogic/` or `dist/x86_64/`. GitHub Actions runs fast host checks on normal
pushes, pull requests, and every release tag. The two architecture builds run
only for a `v*` tag or a manual workflow dispatch, avoiding duplicate SDK builds
for every commit. CI
caches each architecture's checksum-pinned SDK archive and Cargo downloads,
while the build script still verifies the SDK SHA-256 on every run. A tag must
match `v${WLOC_VERSION}-r${WLOC_RELEASE}` and creates a GitHub Release containing
both architecture-specific APKs and their SHA-256 files.

## Install

Copy the APK for your architecture to the router and install it:

```sh
apk add --allow-untrusted ./luci-app-wloc-*.apk
```

Open **Services > WLOC** in LuCI, add an AP, select its BSSID, and enter its
fixed WGS84 latitude and longitude baseline, then save and apply. On every service start,
the first real location establishes the reference. Every later response uses
the fixed virtual baseline plus the difference between the current and previous
real location. The upstream accuracy is preserved unchanged. Install the
generated CA profile on the devices and explicitly enable full trust in iOS
Certificate Trust Settings. Each AP can use the router's direct connection, an
HTTP CONNECT proxy, or an unauthenticated SOCKS5 proxy for its Apple WLOC traffic.

The generated CA key and certificate are retained by OpenWrt sysupgrade so
trusted devices do not unexpectedly lose interception after a firmware update.
Because a sysupgrade backup therefore contains the private CA key, store backup
archives securely. The downloadable mobileconfig uses stable identifiers and is
rewritten only when its CA changes.

The default local listener is TCP port `61520`. Upgrades migrate the previous
`8443`, `58443`, and `28443` defaults while retaining any other custom port. WLOC checks
that the selected port is free before installing interception rules and stops
safely if another router service already owns it.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
