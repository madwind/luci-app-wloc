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
	ip (>=0), \
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
upgrade_running='/tmp/wloc-upgrade.running'

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
	. /lib/functions.sh
	migrate_outbound_index=0
	migrate_outbound_changed=0
	migrate_outbound_rule() {
		local section="$$1" outbound legacy_type legacy_host legacy_port tproxy_port tproxy_mark port mark
		config_get outbound "$$section" outbound ''
		config_get legacy_type "$$section" proxy_type ''
		config_get legacy_host "$$section" proxy_host ''
		config_get legacy_port "$$section" proxy_port ''
		config_get tproxy_port "$$section" tproxy_port ''
		config_get tproxy_mark "$$section" tproxy_mark ''

		if [ -z "$$outbound" ]; then
			case "$$legacy_type" in
				socks5)
					port=$$((12345 + migrate_outbound_index))
					mark=$$((1 | ((migrate_outbound_index & 255) << 8) | ((migrate_outbound_index >> 8) << 17)))
					/sbin/uci -q set "wloc.$$section.outbound=tproxy"
					[ -n "$$tproxy_port" ] || /sbin/uci -q set "wloc.$$section.tproxy_port=$$port"
					[ -n "$$tproxy_mark" ] || /sbin/uci -q set "wloc.$$section.tproxy_mark=0x$$(printf '%x' "$$mark")"
					;;
				direct|'')
					/sbin/uci -q set "wloc.$$section.outbound=direct"
					;;
			esac
			migrate_outbound_changed=1
		fi

		if [ -n "$$legacy_type$$legacy_host$$legacy_port" ]; then
			/sbin/uci -q delete "wloc.$$section.proxy_type"
			/sbin/uci -q delete "wloc.$$section.proxy_host"
			/sbin/uci -q delete "wloc.$$section.proxy_port"
			migrate_outbound_changed=1
		fi
		migrate_outbound_index=$$((migrate_outbound_index + 1))
	}
	config_load wloc
	config_foreach migrate_outbound_rule wifi
	if [ "$$migrate_outbound_changed" -eq 1 ]; then
		/sbin/uci -q commit wloc || logger -t wloc "cannot migrate legacy outbound configuration"
	fi

	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/usr/bin/ucode /usr/libexec/wloc/update.uc auto-sync >/dev/null 2>&1 || logger -t wloc "cannot synchronize automatic update check schedule"
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
			[ -f /usr/libexec/wloc/update.uc ] && /usr/bin/ucode /usr/libexec/wloc/update.uc auto-remove >/dev/null 2>&1 || true
			[ -x /etc/init.d/wloc ] && /etc/init.d/wloc stop >/dev/null 2>&1 || true
			rm -f /usr/share/wloc/installed-version /tmp/wloc-upgrade.running
			;;
	esac
	[ -f /usr/libexec/wloc/firewall.uc ] && /usr/bin/ucode /usr/libexec/wloc/firewall.uc remove-runtime >/dev/null 2>&1 || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature