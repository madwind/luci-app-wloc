# luci-app-wloc

`luci-app-wloc` is a small OpenWrt package that assigns a virtual Apple WLOC
location baseline to each selected access point and follows each real movement
delta from that fixed baseline. It includes a native Rust service, isolated
nftables rules, UCI/procd integration, RPC support, and a LuCI interface.

![WLOC LuCI dashboard](docs/images/wloc-dashboard.png)

Each entry binds one exact configured wireless interface to one virtual
location and optional outbound proxy. The selected `iface` is the fixed
`ifname` from a `wifi-iface`; wireless sections without one are not shown in
LuCI and are ignored by WLOC. The configured SSID is displayed for reference
only and does not identify a rule. The wireless `disabled` state does not hide
a fixed interface. Requests whose client cannot be associated with a matching
hostapd interface pass through unchanged. Use this package only on devices
you own or are authorized to test.

Each interface can also be given a daily disable window in router local time.
During the window, WLOC resolves the interface to its configured `wifi-iface`,
applies a temporary runtime `disabled` override, and reloads WiFi; the
original wireless UCI value is restored when the window ends and is never
committed by WLOC.
Equal start and end times mean all day, and an end time earlier than the start
crosses midnight. If the fixed interface is missing or ambiguous, WLOC records
a warning and leaves every other AP unchanged; it never falls back to another
AP or the whole wireless configuration.

WLOC owns exactly two nftables tables:

```text
table bridge wloc
table inet wloc
```

The nftables editor accepts declarative definitions for those two tables only.
Every table header must use the single-line `table FAMILY NAME {` format; do not
split the header or put the opening brace on a separate line. Normal table
contents such as sets, maps, chains, rules, counters, and flowtables are
validated by `nft --check`. Destructive commands such as `flush ruleset`,
`include`, `delete`, `destroy`, `reset`, `insert`, `replace`, and `add table`
are rejected before any nftables transaction runs. WLOC does not inspect,
modify, or delete any other table, family, or table name.

The packaged ruleset uses `target_ingress_interfaces` (`ifname`, `flags timeout`)
in `table bridge wloc` to select the configured AP interfaces. WLOC refreshes
that set at runtime. The default `table inet wloc` also contains static IPv4 and
IPv6 bypass sets used by the TPROXY chain. If the managed ingress set is absent,
its maintenance is skipped; nftables reports other set or ruleset errors.

For example, these APs may share one bridge without sharing a WLOC identity:

```text
phy0-ap0      ─┐
phy0-ap1      ─┼─ br-lan
phy1-ap0      ─┘
```

Binding `phy0-ap0` to Los Angeles and `phy0-ap1` to Tokyo affects only clients
whose hostapd association reports the corresponding interface; `phy1-ap0` and
wired clients pass through unless they receive their own WLOC rule.

WLOC does not inspect or rewrite nftables rule priority. The relationship between
custom rules and the WLOC listener is entirely controlled by the ruleset you
enter.

The packaged firewall marks traffic from selected ingress interfaces and uses a
TPROXY prerouting chain plus policy routing to deliver matching TCP and UDP to
the local WLOC listener. It does not install an OUTPUT hook. After WLOC handles
a connection, its upstream socket is ordinary router-local output, so another
transparent proxy with an OUTPUT policy can process that upstream traffic. The
policy-routing controller refuses to replace a conflicting route owned by
another component.

The firewall source supports the runtime placeholder `%port%`. It is resolved
to `wloc.main.listen_port` immediately before nftables validation and apply, so
the saved template and the daemon listener stay synchronized without hardcoding
the default `61520` port.

## Supported OpenWrt targets

- `mediatek/filogic` (`aarch64_cortex-a53`)
  - example: Xiaomi AX3000T
  - other compatible OpenWrt 25.12.5 Filogic devices
- `rockchip/armv8` (`aarch64_generic`)
  - compatible OpenWrt 25.12.5 Rockchip armv8 devices
  - NanoPi R28S running FriendlyWrt 25.12 uses the same
    `aarch64_generic` package architecture; the WLOC APK is built with the
    official OpenWrt 25.12.5 `rockchip/armv8` SDK
- `x86/64` (`x86_64`)

NanoPi R28S firmware in this documentation means FriendlyWrt 25.12. The WLOC
package is built with the official OpenWrt 25.12.5 `rockchip/armv8` SDK; the
R28S firmware distribution and the SDK used to build WLOC are separate
concepts. FriendlyWrt's RK3528 build configuration uses
`build_dir/target-aarch64_generic_musl/root-rockchip`, which is why the
package architecture is `aarch64_generic`.

## Build

Run the build on Linux x86_64. WSL2 is also supported.

Package versions are configured only in `version.env`. Update
`WLOC_VERSION` for an application release, and `WLOC_RELEASE` when rebuilding
the same application version with packaging-only changes.

```sh
# MediaTek Filogic
bash ./scripts/build-apk.sh mediatek/filogic

# Rockchip ARMv8
bash ./scripts/build-apk.sh rockchip/armv8

# x86/64
bash ./scripts/build-apk.sh x86/64
```

The script downloads and verifies the official OpenWrt SDK, builds the native
musl binary and APK package, validates the result, and writes artifacts to
`dist/mediatek/filogic/`, `dist/rockchip/armv8/`, or `dist/x86/64/`. The release
workflow builds all three targets, validates the APK artifacts, generates
SHA-256 files, and publishes the GitHub Release. It caches each architecture's
checksum-pinned SDK archive and Cargo downloads, while the build script still
verifies the SDK SHA-256 on every run. A tag must match
`v${WLOC_VERSION}-r${WLOC_RELEASE}` and creates a GitHub Release containing
target-specific assets and their SHA-256 files:

```text
luci-app-wloc-<version>-r<release>-mediatek-filogic.apk
luci-app-wloc-<version>-r<release>-mediatek-filogic.apk.sha256
luci-app-wloc-<version>-r<release>-rockchip-armv8.apk
luci-app-wloc-<version>-r<release>-rockchip-armv8.apk.sha256
luci-app-wloc-<version>-r<release>-x86-64.apk
luci-app-wloc-<version>-r<release>-x86-64.apk.sha256
```

## Install

Copy the APK for your architecture to the router and install it:

```sh
apk add --allow-untrusted ./luci-app-wloc-*.apk
```

Open **Services > WLOC** in LuCI, add an AP, select its exact fixed interface,
and enter its fixed WGS84 latitude and longitude baseline, then save and apply.
Add a fixed `option ifname` to each selected `wifi-iface` in
`/etc/config/wireless`. WLOC stores the fixed interface, shows its configured
SSID as a third-column reference, and adds the interface directly; it does not
scan the bridge or runtime interfaces. A missing fixed name means the AP is
not shown and cannot be selected. Changing the SSID does not affect the rule;
changing or removing the fixed interface requires selecting the new interface
in the rule. On every
service start, the first real location establishes the reference. Every later
response uses the fixed virtual baseline plus the difference between the
current and previous real location. The upstream accuracy is preserved
unchanged. Install the
generated CA profile on the devices and explicitly enable full trust in iOS
Certificate Trust Settings. Each AP can use the router's direct connection or
an unauthenticated SOCKS5 proxy for its Apple WLOC traffic.

The generated CA key and certificate are retained by OpenWrt sysupgrade so
trusted devices do not unexpectedly lose interception after a firmware update.
Because a sysupgrade backup therefore contains the private CA key, store backup
archives securely. The downloadable mobileconfig uses stable identifiers and is
rewritten only when its CA changes.

Upgrades and reinstalls, as well as the package's ordinary uninstall hook, do
not delete the user-generated CA state under `/etc/wloc`. If you intentionally
want to reset trust, stop WLOC and remove `ca.key`, `ca.der`, `ca.pem`,
`ca.info.json`, and `/www/wloc-ca.mobileconfig` explicitly before generating a
new CA.

The default local listener is TCP and UDP port `61520` and can be changed in
LuCI under Service settings. The packaged firewall uses `%port%`, so changing
that setting changes both the daemon listener and the runtime TPROXY target.
WLOC runs with the service's existing user and group identity; it does not
change the daemon GID. Upgrades migrate the previous `8443`, `58443`, and
`28443` defaults while retaining any other custom port. WLOC checks that the
selected port is free before installing interception rules and stops safely if
another router service already owns it.

WLOC intercepts exactly these two fixed Apple WLOC endpoints:

- `gs-loc.apple.com`
- `gs-loc-cn.apple.com`

They are shown as read-only values in Service settings and are not configurable.
The optional debug mode returns `{"wloc":"ok"}` for requests to these endpoints
without contacting the upstream server.

The LuCI **Interception status** reports whether the service is actually usable:
`Active`, `Recovering`, `Error`, `Disabled`, or `Traffic conflict`. In the
firewall editor, **Check syntax** validates the table definitions, **Apply**
only changes runtime firewall state, and **Save** persists the current editor
revision. Rebooting without Save restores the last saved persistent rules.
All firewall state transitions are restricted to the two WLOC-owned tables.

The firewall snapshots have distinct roles:

```text
/etc/wloc/firewall.nft
    persistent rules loaded after reboot

/var/run/wloc/firewall.applied.nft
    authoritative runtime snapshot of the successfully applied revision

/var/run/wloc/firewall.applied.nft.next
    staging snapshot used while applying a new firewall revision
    normally promoted or removed immediately; it is not an ownership database
```

WLOC immediately reconciles its dynamic ingress set and policy route when the
listener is ready; if the daemon or a runtime update is temporarily unavailable,
cleanup is fail-open and the daemon retries reconciliation automatically. Normal
firewall or runtime recovery does not require a manual **Restart service**.
When the package is uninstalled, its lifecycle hook deletes `table bridge wloc`
and `table inet wloc` and removes the runtime snapshots. Unrelated tables are
not touched.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
