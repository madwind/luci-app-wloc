# luci-app-wloc

`luci-app-wloc` is a LuCI plugin for OpenWrt that intercepts Apple WLOC traffic and applies a configurable virtual location baseline per selected wireless interface.

It includes a native Rust service, nftables interception, policy routing, UCI/procd integration and a LuCI interface.

## Install

OpenWrt 25.12+:

```sh
wget -qO- https://raw.githubusercontent.com/madwind/luci-app-wloc/master/install.sh | sh
```

The installer detects the current package architecture, reads the latest GitHub Release metadata, verifies the matching APK against the release asset SHA256 digest and installs or upgrades WLOC.

Supported release targets:

- `mediatek/filogic` (`aarch64_cortex-a53`)
- `rockchip/armv8` (`aarch64_generic`)
- `x86/64` (`x86_64`)

## Features

- Assign a virtual WGS84 location baseline to each selected wireless interface
- Preserve real movement deltas relative to the configured virtual baseline
- Per-rule Direct or user-defined TPROXY port outbound selection with automatic internal marks
- Per-interface daily enable/disable schedule
- Generate and manage the local CA profile required for WLOC interception
- Intercept `gs-loc.apple.com` and `gs-loc-cn.apple.com`
- Edit, validate, install and uninstall nftables rules independently from wlocd
- Edit, install and uninstall policy routing independently from wlocd
- Use `%port%` in firewall rules to follow the configured WLOC listener port
- View service, interception and runtime status in LuCI
- Check and update WLOC from GitHub Releases
- Optional weekly automatic update checks

WLOC owns only these nftables tables:

```text
table bridge wloc
table inet wloc
```

The packaged firewall uses the selected wireless interfaces for ingress matching and WLOC interception. A rule may send its outbound sockets directly or dispatch them to a user-defined TPROXY listener port; WLOC assigns the internal profile marks automatically from rule order. TCP, UDP, DNS-over-HTTPS upstreams and Apple WLOC MITM traffic all use the same selected outbound.

Firewall and Routing are independent services. Installing either component enables it at boot, and stopping wlocd does not remove it. The Firewall template is rendered even when no dynamic location targets are available; wlocd refreshes those target values while it runs and clears them when it stops.

## Usage

Open **Services > WLOC** in LuCI, select a wireless interface and configure its virtual latitude and longitude.

Each managed `wifi-iface` should have a fixed `option ifname` in `/etc/config/wireless`. WLOC binds rules to that interface name rather than to the SSID.

Install the generated CA profile on the client device and enable full trust for the certificate in iOS Certificate Trust Settings.

The default TCP/UDP listener port is `61520` and can be changed in LuCI.

## Runtime requirements

WLOC targets OpenWrt 25.12+ with LuCI. The package includes the native `wlocd` Rust service and declares its required OpenWrt runtime dependencies.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
