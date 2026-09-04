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
	kmod-nft-bridge (>=0), \
	kmod-nft-fib (>=0), \
	kmod-nft-tproxy (>=0), \
	uclient-fetch (>=0)

LUCI_DESCRIPTION:=Apple WLOC TLS patching plus per-WiFi transparent TCP/UDP proxying for OpenWrt. Includes wlocd, UCI/procd lifecycle, isolated nftables rules, native ucode runtime and rpcd controllers, and LuCI.
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
endef

define Package/luci-app-wloc/postinst
#!/bin/sh
postinst_root="$${IPKG_INSTROOT}"
version_cache="$${postinst_root}/usr/share/wloc/installed-version"

mkdir -p "$${postinst_root}/usr/share/wloc" || exit 1
printf '%s\n' '$(PKG_VERSION)-r$(PKG_RELEASE)' >"$${version_cache}" || exit 1
chmod 0644 "$${version_cache}" 2>/dev/null || true
chmod 0755 \
	"$${postinst_root}/etc/init.d/wloc" \
	"$${postinst_root}/usr/libexec/wloc/ap.uc" \
	"$${postinst_root}/usr/libexec/wloc/firewall.uc" \
	"$${postinst_root}/usr/libexec/wloc/routing.uc" \
	"$${postinst_root}/usr/libexec/wloc/rpc.uc" \
	"$${postinst_root}/usr/libexec/wloc/rules.uc" \
	"$${postinst_root}/usr/libexec/wloc/update.uc" \
	"$${postinst_root}/usr/libexec/wloc/wifi-schedule.uc" 2>/dev/null || true
chmod 0644 "$${postinst_root}/usr/share/rpcd/ucode/"luci.wloc*.uc 2>/dev/null || true

[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/usr/bin/ucode /usr/libexec/wloc/update.uc auto-sync >/dev/null 2>&1 || logger -t wloc "cannot synchronize automatic update check schedule"
	exit 0
}
exit 0
endef

define Package/luci-app-wloc/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	case "$${1:-remove}" in
		upgrade) ;;
		*)
			[ -f /usr/libexec/wloc/update.uc ] && /usr/bin/ucode /usr/libexec/wloc/update.uc auto-remove >/dev/null 2>&1 || true
			rm -f /usr/share/wloc/installed-version
			;;
	esac
	[ -f /usr/libexec/wloc/firewall.uc ] && /usr/bin/ucode /usr/libexec/wloc/firewall.uc remove-runtime >/dev/null 2>&1 || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
