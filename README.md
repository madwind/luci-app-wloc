# luci-app-wloc

`luci-app-wloc` is a small OpenWrt package that assigns a virtual Apple WLOC
location baseline to each selected access point and follows each real movement
delta from that fixed baseline. It includes a native Rust service, isolated
nftables rules, UCI/procd integration, RPC support, and a LuCI interface.

![WLOC LuCI dashboard](docs/images/wloc-dashboard.png)

Each entry binds one exact, case-sensitive configured SSID to one virtual
location and optional outbound proxy. SSID is the only persistent AP identity.
At runtime WLOC resolves it through `/etc/config/wireless` to the current
wireless section, network, bridge/device, interfaces, and hostapd state; those
values are metadata and are never used as the rule identity. Each SSID may be
used by only one WLOC entry, while different SSIDs may share the same bridge.
Requests whose client cannot be associated with a matching hostapd SSID pass
through unchanged. Use this package only on devices you own or are authorized
to test.

Each SSID can also be given a daily disable window in router local time. During
the window, WLOC resolves the SSID to its current `wifi-iface`, applies a
temporary runtime `disabled` override, and reloads WiFi; the original wireless
UCI value is restored when the window ends and is never committed by WLOC.
Equal start and end times mean all day, and an end time earlier than the start
crosses midnight. If the SSID is missing or ambiguous, WLOC records a warning
and leaves every other AP unchanged; it never falls back to another AP or the
whole radio.

The nftables rules resolve each configured SSID to its network device and
current bridge members, place those runtime ingress interfaces in a short-lived
interface set, and then match the resolved IPv4 addresses of both Apple WLOC
hostnames and TCP/443. Different configured SSIDs can therefore share `br-lan`;
the ingress set is deduplicated. This may capture traffic from other APs or
wired clients on that bridge, but WLOC confirms the client through
IP-to-MAC-to-hostapd-to-SSID discovery before applying a location rule, so
unconfigured SSIDs and wired clients pass through.

For example, these APs may share one bridge without sharing a WLOC identity:

```text
SSID-US      ─┐
SSID-JP      ─┼─ br-lan
SSID-NORMAL  ─┘
```

Binding `SSID-US` to Los Angeles and `SSID-JP` to Tokyo affects only clients
whose hostapd association reports the corresponding SSID; `SSID-NORMAL` and
wired clients pass through unless they receive their own WLOC rule.

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

Open **Services > WLOC** in LuCI, add an AP, select its exact configured SSID,
and enter its fixed WGS84 latitude and longitude baseline, then save and apply.
WLOC stores only the SSID. Wireless sections, network bridges, runtime
interfaces, and BSSIDs are rediscovered as needed, so changing a BSSID,
interface name, or wireless section does not invalidate the rule. Renaming the
SSID intentionally breaks the binding: WLOC reports that the configured SSID
was not found, and you must select the renamed SSID in the rule. On every
service start, the first real location establishes the reference. Every later
response uses the fixed virtual baseline plus the difference between the
current and previous real location. The upstream accuracy is preserved
unchanged. Install the
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
