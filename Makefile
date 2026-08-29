PKG_DIR:=$(dir $(lastword $(MAKEFILE_LIST)))
include $(TOPDIR)/rules.mk
include $(PKG_DIR)version.env

PKG_NAME:=luci-app-wloc
PKG_VERSION:=$(WLOC_VERSION)
PKG_RELEASE:=$(WLOC_RELEASE)
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE NOTICE
PKG_MAINTAINER:=luci-app-wloc maintainers

LUCI_TITLE:=Apple WLOC movement-following location proxy for OpenWrt

# wlocd currently ships musl binaries only for these OpenWrt architectures.
# Keep runtime-only packages in LUCI_EXTRA_DEPENDS below.
LUCI_DEPENDS:=@(aarch64||x86_64)

# Runtime dependencies only. They are written into the APK metadata
# without pulling the whole target dependency tree into this SDK build.
LUCI_EXTRA_DEPENDS:= \
	luci-base (>=0), \
	nftables (>=0), \
	jshn (>=0)

LUCI_DESCRIPTION:=Selective Apple WLOC TLS proxy with one location rule per fixed wireless interface. Includes wlocd, UCI/procd lifecycle, isolated nftables rules, rpcd and LuCI.
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
endef

define Package/luci-app-wloc/prerm
#!/bin/sh
# The package framework runs default_prerm first; keep only WLOC-specific cleanup here.
[ -n "$${IPKG_INSTROOT}" ] || {
	/usr/libexec/wloc/firewall.sh remove-runtime 2>/dev/null || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
