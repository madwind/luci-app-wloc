PKG_DIR:=$(dir $(lastword $(MAKEFILE_LIST)))
include $(TOPDIR)/rules.mk
include $(PKG_DIR)version.env

PKG_NAME:=luci-app-wloc
PKG_VERSION:=$(WLOC_VERSION)
PKG_RELEASE:=$(WLOC_RELEASE)
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE NOTICE

LUCI_TITLE:=Apple WLOC movement-following location proxy for OpenWrt

# wlocd currently ships musl binaries only for these OpenWrt architectures.
# Keep runtime-only packages in LUCI_EXTRA_DEPENDS below.
LUCI_DEPENDS:=@(aarch64||x86_64)

# Runtime dependencies only. They are written into the APK metadata
# without pulling the whole target dependency tree into this SDK build.
LUCI_EXTRA_DEPENDS:= \
	luci-base (>=0), \
	nftables (>=0), \
	kmod-nft-tproxy (>=0), \
	ip-full (>=0), \
	jshn (>=0), \
	lua (>=0), \
	uclient-fetch (>=0)

LUCI_DESCRIPTION:=Apple WLOC TLS patching plus per-WiFi transparent TCP/UDP proxying for OpenWrt. Includes wlocd, UCI/procd lifecycle, isolated nftables rules, GeoIP macros, rpcd and LuCI.
LUCI_MAINTAINER:=luci-app-wloc maintainers
LUCI_URL:=https://github.com/madwind/luci-app-wloc

ifeq ($(DUMP),)
  ifeq ($(ARCH),aarch64)
    RUST_TARGET:=aarch64-unknown-linux-musl
    RUST_LINKER_ENV:=CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER
  else ifeq ($(ARCH),x86_64)
    RUST_TARGET:=x86_64-unknown-linux-musl
    RUST_LINKER_ENV:=CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER
  else
    $(error Unsupported OpenWrt architecture: $(ARCH))
  endif
endif

include $(TOPDIR)/feeds/luci/luci.mk

export RUST_TARGET RUST_LINKER_ENV TARGET_CC_NOCACHE TARGET_AR TARGET_CFLAGS

define Package/luci-app-wloc/conffiles
/etc/config/wloc
/etc/wloc/firewall.nft
/etc/wloc/routing.conf
endef

define Package/luci-app-wloc/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 0755 \
		/usr/libexec/rpcd/luci.wloc.service \
		/usr/libexec/rpcd/luci.wloc.update \
		/usr/libexec/rpcd/luci.wloc.defaults \
		/usr/libexec/rpcd/luci.wloc.firewall \
		/usr/libexec/rpcd/luci.wloc.geo \
		/usr/libexec/rpcd/luci.wloc.geoauto \
		/usr/libexec/wloc/update.sh \
		/usr/libexec/wloc/geo-update.sh \
		/usr/libexec/wloc/geo-smart-update.sh \
		/usr/libexec/wloc/geo-auto.sh \
		/usr/libexec/wloc/firewall.sh \
		/usr/libexec/wloc/firewall-core.sh \
		/usr/libexec/wloc/firewall-geo.lua 2>/dev/null || true
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/usr/libexec/wloc/geo-auto.sh sync >/dev/null 2>&1 || logger -t wloc "cannot synchronize automatic GeoIP update schedule"
	exit 0
}
exit 0
endef

define Package/luci-app-wloc/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	case "$${1:-remove}" in
		upgrade) ;;
		*) [ -x /usr/libexec/wloc/geo-auto.sh ] && /usr/libexec/wloc/geo-auto.sh remove >/dev/null 2>&1 || true;;
	esac
	/usr/libexec/wloc/firewall.sh remove-runtime 2>/dev/null || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
