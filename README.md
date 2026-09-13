# luci-app-wloc

**WLOC** stands for **Wireless Link Orchestration Controller**.

`luci-app-wloc` is a LuCI package for OpenWrt that coordinates per-interface link policies, traffic processing and routing behavior. It is intended to provide a small control layer between wireless interfaces, nftables and policy routing without coupling the configuration to a specific network topology.

It includes a native Rust service, nftables integration, policy routing, UCI/procd integration and a LuCI interface.

## Install

OpenWrt 25.12+ packages are distributed through the signed `madwind/openwrt-packages` repository:

```sh
wget -O- https://raw.githubusercontent.com/madwind/openwrt-packages/main/install.sh | sh
apk add luci-app-wloc
```

To refresh repository metadata and upgrade WLOC:

```sh
apk update
apk add --upgrade luci-app-wloc
```

Supported release targets:

- `mediatek/filogic` (`aarch64_cortex-a53`)
- `rockchip/armv8` (`aarch64_generic`)
- `x86/64` (`x86_64`)

## Features

- Per-interface configuration and rule management
- Direct or user-defined TPROXY outbound selection
- Per-interface daily enable/disable schedules
- Local CA profile management
- nftables firewall rule management
- Policy routing management
- Automatic firewall and routing lifecycle handling
- Runtime and service status in LuCI

WLOC owns only these nftables tables:

```text
table bridge wloc
table inet wloc
```

Firewall and routing rules are managed as part of the WLOC runtime lifecycle. Startup installs the saved configuration; normal stop and guarded failure cleanup remove the active rules.

## Usage

Open **Services > WLOC** in LuCI and configure the required interfaces and rules.

Each managed `wifi-iface` should have a fixed `option ifname` in `/etc/config/wireless`. WLOC binds rules to that interface name rather than to the SSID.

The default TCP/UDP listener port is `61520` and can be changed in LuCI.

## Runtime requirements

WLOC targets OpenWrt 25.12+ with LuCI. The package includes the native `wlocd` Rust service and declares its required OpenWrt runtime dependencies.

## License

MIT. See [LICENSE](LICENSE).
