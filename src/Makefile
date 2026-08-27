include $(TOPDIR)/rules.mk

RUST_TARGET ?= $(error RUST_TARGET is not set)

# luci.mk copies src/ to PKG_BUILD_DIR/src and runs make from there, but the
# Cargo.toml that should drive the build is at the top of PKG_BUILD_DIR.
CARGO_BUILD_DIR := $(CURDIR)/wloc-rs
ifneq ($(wildcard $(CURDIR)/../Cargo.toml),)
  CARGO_BUILD_DIR := $(CURDIR)/..
endif

all: compile

compile:
	cd "$(CARGO_BUILD_DIR)" && \
		CC_$(subst -,_,$(RUST_TARGET))="$(TARGET_CC_NOCACHE)" \
		AR_$(subst -,_,$(RUST_TARGET))="$(TARGET_AR)" \
		CFLAGS_$(subst -,_,$(RUST_TARGET))="$(TARGET_CFLAGS)" \
		$(RUST_LINKER_ENV)="$(TARGET_CC_NOCACHE)" \
		RUSTFLAGS="-C target-feature=-crt-static -C link-self-contained=no -C link-arg=-Wl,--gc-sections" \
		cargo build --locked --release --target $(RUST_TARGET)

clean:
	rm -rf "$(CARGO_BUILD_DIR)/target"

install:
	$(INSTALL_DIR) $(DESTDIR)/usr/sbin
	$(INSTALL_BIN) $(CARGO_BUILD_DIR)/target/$(RUST_TARGET)/release/wlocd $(DESTDIR)/usr/sbin/wlocd
