include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wloc
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_PARALLEL:=1

RUSTC_TARGET_ARCH:=aarch64-unknown-linux-musl
RUSTC_TARGET_UPPER:=AARCH64_UNKNOWN_LINUX_MUSL
RUSTC_CFLAGS:=-mno-outline-atomics
CARGO_RUSTFLAGS:=-Ctarget-feature=-crt-static

LUCI_TITLE:=Wireless Link Orchestration Controller for OpenWrt
LUCI_DEPENDS:=@aarch64
LUCI_EXTRA_DEPENDS:= \
	luci-base (>=0), \
	nftables (>=0), \
	kmod-nft-bridge (>=0), \
	kmod-nft-fib (>=0), \
	kmod-nft-tproxy (>=0), \
	ip (>=0)
LUCI_DESCRIPTION:=Per-interface link policy orchestration, transparent traffic processing, nftables and policy routing for OpenWrt. Includes wlocd, UCI/procd lifecycle, native ucode runtime and rpcd controllers, and LuCI.
LUCI_MAINTAINER:=Ivon Wei <madwind.cn@gmail.com>
LUCI_URL:=https://github.com/madwind/luci-app-wloc

ifneq ($(wildcard ../../luci.mk),)
include ../../luci.mk
else
include $(TOPDIR)/feeds/luci/luci.mk
endif

export RUSTC_TARGET_ARCH RUSTC_TARGET_UPPER CARGO_RUSTFLAGS
export RUSTC_CFLAGS TARGET_AR TARGET_CC_NOCACHE TARGET_CFLAGS WLOC_CARGO_TARGET_DIR

define Package/luci-app-wloc/conffiles
/etc/config/wloc
endef

define Package/luci-app-wloc/postinst
#!/bin/sh
upgrade_running='/tmp/wloc-upgrade.running'

[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	if [ "$$(uci -q get wloc.main.enabled 2>/dev/null)" = "1" ]; then
		/etc/init.d/wloc enable >/dev/null 2>&1 || true
		if [ "$${WLOC_DEFER_RESTART:-0}" != "1" ] && [ -f "$${upgrade_running}" ]; then
			/etc/init.d/wloc start >/dev/null 2>&1 || logger -t wloc "service restart after package upgrade failed"
		fi
	else
		/etc/init.d/wloc disable >/dev/null 2>&1 || true
	fi
	rm -f "$${upgrade_running}"
	exit 0
}
exit 0
endef

define Package/luci-app-wloc/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	case "$${1:-remove}" in
		upgrade)
			rm -f /tmp/wloc-upgrade.running
			pidof wlocd >/dev/null 2>&1 && : > /tmp/wloc-upgrade.running
			[ -x /etc/init.d/wloc ] && /etc/init.d/wloc stop >/dev/null 2>&1 || true
			;;
		*)
			[ -x /etc/init.d/wloc ] && /etc/init.d/wloc stop >/dev/null 2>&1 || true
			rm -f /tmp/wloc-upgrade.running
			;;
	esac
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
