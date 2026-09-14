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
		CARGO_BUILD_TARGET="$(RUSTC_TARGET_ARCH)" \
		CARGO_HOME="$(CARGO_HOME)" \
		CARGO_TARGET_$(RUSTC_TARGET_UPPER)_LINKER="$(TARGET_CC_NOCACHE)" \
		RUSTFLAGS="$(CARGO_RUSTFLAGS)" \
		TARGET_CC="$(TARGET_CC_NOCACHE)" \
		TARGET_CFLAGS="$(TARGET_CFLAGS) $(RUSTC_CFLAGS)" \
		cargo build --locked --release --target "$(RUSTC_TARGET_ARCH)"

clean:
	rm -rf "$(CARGO_BUILD_DIR)/target"

install:
	$(INSTALL_DIR) $(DESTDIR)/usr/sbin
	$(INSTALL_BIN) $(CARGO_BUILD_DIR)/target/$(RUSTC_TARGET_ARCH)/release/wlocd $(DESTDIR)/usr/sbin/wlocd
