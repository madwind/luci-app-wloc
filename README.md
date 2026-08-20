# luci-app-wloc

`luci-app-wloc` is a small OpenWrt package that assigns a virtual Apple WLOC
location baseline to each authorized device and follows each real movement
delta from that fixed baseline. It includes a native Rust service, isolated
nftables rules, UCI/procd integration, RPC support, and a LuCI interface.

![WLOC LuCI dashboard](docs/images/wloc-dashboard.png)

Enabled rules are evaluated in their UCI/LuCI order and the first matching rule
wins. A rule can select one MAC or all wireless devices, and can select one AP
by BSSID or accept any wireless source. SSID is display metadata only. Requests
without a matching rule pass through unchanged. Use this package only on
devices you own or are authorized to test.

The nftables rules put explicitly selected devices in a MAC set and AP-wide
rules in a hostapd interface set, then match the resolved IPv4 addresses of
both Apple WLOC hostnames and TCP/443. They do not capture the whole LAN bridge.
Before installing its
REDIRECT, WLOC scans all IPv4-capable prerouting base chains and follows their
`jump`/`goto` paths to find every reachable REDIRECT or TPROXY verdict. It then
chooses a numeric priority earlier than all detected transparent-proxy ingress
paths (for example, priority `-152` when the earliest proxy uses `mangle - 1`,
or `-151`). WLOC stays after conntrack priority `-200`, which REDIRECT requires;
if no safe, verifiable priority exists, startup fails instead of claiming an
ordering guarantee it cannot provide. The chosen priority and every detected
proxy chain, priority, verdict type, path type, and relative order are written
to the system log in numeric priority order. LuCI also reports the selected
ingress priority and whether the order is verified.

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
`dist/filogic/` or `dist/x86_64/`. GitHub Actions builds both targets on every
push and pull request. CI caches each architecture's checksum-pinned SDK archive
and Cargo downloads, while the build script still verifies the SDK SHA-256 on
every run. Pushing a `v*` tag creates a GitHub Release containing both
architecture-specific APKs and their SHA-256 files.

## Install

Copy the APK for your architecture to the router and install it:

```sh
apk add --allow-untrusted ./luci-app-wloc-*.apk
```

Open **Services > WLOC** in LuCI, add rules, drag them into priority order, enter
each fixed WGS84 latitude and longitude baseline, then save and apply. On every service start,
the first real location establishes the reference. Every later response uses
the fixed virtual baseline plus the difference between the current and previous
real location. The upstream accuracy is preserved unchanged. Install the
generated CA profile on that device and explicitly enable full trust in iOS
Certificate Trust Settings. Each rule can use the router's direct
connection, an HTTP CONNECT proxy, or an unauthenticated SOCKS5 proxy for its
Apple WLOC traffic.

The default local listener is TCP port `61520`. Upgrades migrate the previous
`8443`, `58443`, and `28443` defaults while retaining any other custom port. WLOC checks
that the selected port is free before installing interception rules and stops
safely if another router service already owns it.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
