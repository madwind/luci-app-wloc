include $(TOPDIR)/rules.mk

RUSTC_TARGET_ARCH ?= $(error RUSTC_TARGET_ARCH is not set)
RUSTC_TARGET_UPPER ?= $(error RUSTC_TARGET_UPPER is not set)
RUST_TARGET_ENV := $(subst -,_,$(RUSTC_TARGET_ARCH))
OPENWRT_RUST_LDFLAGS := $(foreach flag,$(TARGET_LDFLAGS),-Clink-arg=$(flag))

# luci.mk copies src/ to PKG_BUILD_DIR/src and runs make from there, while the
# Rust crate is kept in the wloc-rs subdirectory.
CARGO_BUILD_DIR := $(CURDIR)/wloc-rs
ifneq ($(wildcard $(CURDIR)/../Cargo.toml),)
  CARGO_BUILD_DIR := $(CURDIR)/..
endif
CARGO_TARGET_DIR := $(if $(WLOC_CARGO_TARGET_DIR),$(WLOC_CARGO_TARGET_DIR),$(CARGO_BUILD_DIR)/target)

all: compile

compile:
	cd "$(CARGO_BUILD_DIR)" && \
		CC_$(RUST_TARGET_ENV)="$(TARGET_CC_NOCACHE)" \
		AR_$(RUST_TARGET_ENV)="$(TARGET_AR)" \
		CFLAGS_$(RUST_TARGET_ENV)="$(TARGET_CFLAGS) $(RUSTC_CFLAGS)" \
		CARGO_BUILD_TARGET="$(RUSTC_TARGET_ARCH)" \
		CARGO_TARGET_DIR="$(CARGO_TARGET_DIR)" \
		CARGO_TARGET_$(RUSTC_TARGET_UPPER)_LINKER="$(TARGET_CC_NOCACHE)" \
		CARGO_TARGET_$(RUSTC_TARGET_UPPER)_RUSTFLAGS="$(strip $(CARGO_RUSTFLAGS) $(OPENWRT_RUST_LDFLAGS))" \
		cargo build --locked --release --target "$(RUSTC_TARGET_ARCH)"

clean:
ifeq ($(WLOC_CARGO_TARGET_DIR),)
	rm -rf "$(CARGO_TARGET_DIR)"
else
	@:
endif

install:
	$(INSTALL_DIR) $(DESTDIR)/usr/sbin
	$(INSTALL_BIN) $(CARGO_TARGET_DIR)/$(RUSTC_TARGET_ARCH)/release/wlocd $(DESTDIR)/usr/sbin/wlocd
