include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wloc
PKG_VERSION:=0.1.4
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE NOTICE
PKG_MAINTAINER:=luci-app-wloc maintainers

include $(INCLUDE_DIR)/package.mk

ifeq ($(ARCH),aarch64)
  RUST_TARGET:=aarch64-unknown-linux-musl
  RUST_LINKER_ENV:=CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER
else ifeq ($(ARCH),x86_64)
  RUST_TARGET:=x86_64-unknown-linux-musl
  RUST_LINKER_ENV:=CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER
else
  $(error Unsupported OpenWrt architecture: $(ARCH))
endif

define Package/luci-app-wloc
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Apple WLOC movement-following location proxy for OpenWrt
  URL:=https://github.com/madwind/luci-app-wloc
  DEPENDS:=+libc +libgcc +nftables +ip-full +rpcd +uhttpd +luci-base
endef

define Package/luci-app-wloc/description
  Selective Apple WLOC TLS proxy with per-device MAC address rules.
  Includes wlocd, UCI/procd lifecycle, isolated nftables rules, rpcd and LuCI.
endef

define Package/luci-app-wloc/conffiles
/etc/config/wloc
endef

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)/src
	$(CP) $(CURDIR)/Cargo.toml $(CURDIR)/Cargo.lock $(PKG_BUILD_DIR)/
	$(CP) $(CURDIR)/src/*.rs $(PKG_BUILD_DIR)/src/
endef

define Build/Compile
	(cd $(PKG_BUILD_DIR); \
		CC_$(subst -,_,$(RUST_TARGET))="$(TARGET_CC_NOCACHE)" \
		AR_$(subst -,_,$(RUST_TARGET))="$(TARGET_AR)" \
		CFLAGS_$(subst -,_,$(RUST_TARGET))="$(TARGET_CFLAGS)" \
		$(RUST_LINKER_ENV)="$(TARGET_CC_NOCACHE)" \
		RUSTFLAGS="-C target-feature=-crt-static -C link-self-contained=no -C link-arg=-Wl,--gc-sections" \
		cargo build --frozen --release --target $(RUST_TARGET))
endef

define Package/luci-app-wloc/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/wlocd $(1)/usr/sbin/wlocd
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) $(CURDIR)/openwrt/files/etc/config/wloc $(1)/etc/config/wloc
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/openwrt/files/etc/init.d/wloc $(1)/etc/init.d/wloc
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/openwrt/files/etc/uci-defaults/luci-app-wloc $(1)/etc/uci-defaults/luci-app-wloc
	$(INSTALL_DIR) $(1)/usr/libexec/wloc
	$(INSTALL_BIN) $(CURDIR)/openwrt/files/usr/libexec/wloc/rules.sh $(1)/usr/libexec/wloc/rules.sh
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) $(CURDIR)/openwrt/files/usr/libexec/rpcd/luci.wloc $(1)/usr/libexec/rpcd/luci.wloc
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(CURDIR)/openwrt/files/usr/share/luci/menu.d/luci-app-wloc.json $(1)/usr/share/luci/menu.d/luci-app-wloc.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/openwrt/files/usr/share/rpcd/acl.d/luci-app-wloc.json $(1)/usr/share/rpcd/acl.d/luci-app-wloc.json
	$(INSTALL_DIR) $(1)/usr/share/ucitrack
	$(INSTALL_DATA) $(CURDIR)/openwrt/files/usr/share/ucitrack/luci-app-wloc.json $(1)/usr/share/ucitrack/luci-app-wloc.json
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(CURDIR)/openwrt/files/lib/upgrade/keep.d/luci-app-wloc $(1)/lib/upgrade/keep.d/luci-app-wloc
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/wloc
	$(INSTALL_DATA) $(CURDIR)/openwrt/files/www/luci-static/resources/view/wloc/main.js $(1)/www/luci-static/resources/view/wloc/main.js
endef

define Package/luci-app-wloc/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/wloc enable
	/etc/init.d/wloc restart || true
}
exit 0
endef

define Package/luci-app-wloc/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/usr/libexec/wloc/rules.sh cleanup 2>/dev/null || true
	/etc/init.d/wloc disable 2>/dev/null || true
	/etc/init.d/wloc stop 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-wloc))
