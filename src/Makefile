include $(TOPDIR)/rules.mk

RUSTC_TARGET_ARCH ?= $(error RUSTC_TARGET_ARCH is not set)
RUSTC_TARGET_UPPER ?= $(error RUSTC_TARGET_UPPER is not set)

# luci.mk copies src/ to PKG_BUILD_DIR/src and runs make from there, while the
# Rust crate is kept in the wloc-rs subdirectory.
CARGO_BUILD_DIR := $(CURDIR)/wloc-rs
ifneq ($(wildcard $(CURDIR)/../Cargo.toml),)
  CARGO_BUILD_DIR := $(CURDIR)/..
endif

all: compile

compile:
	cd "$(CARGO_BUILD_DIR)" && \
		CC_aarch64_unknown_linux_musl="$(TARGET_CC_NOCACHE)" \
		AR_aarch64_unknown_linux_musl="$(TARGET_AR)" \
		CFLAGS_aarch64_unknown_linux_musl="$(TARGET_CFLAGS) $(RUSTC_CFLAGS)" \
		CARGO_BUILD_TARGET="$(RUSTC_TARGET_ARCH)" \
		CARGO_TARGET_$(RUSTC_TARGET_UPPER)_LINKER="$(TARGET_CC_NOCACHE)" \
		CARGO_TARGET_$(RUSTC_TARGET_UPPER)_RUSTFLAGS="$(CARGO_RUSTFLAGS)" \
		cargo build --locked --release --target "$(RUSTC_TARGET_ARCH)"

clean:
	rm -rf "$(CARGO_BUILD_DIR)/target"

install:
	$(INSTALL_DIR) $(DESTDIR)/usr/sbin
	$(INSTALL_BIN) $(CARGO_BUILD_DIR)/target/$(RUSTC_TARGET_ARCH)/release/wlocd $(DESTDIR)/usr/sbin/wlocd
