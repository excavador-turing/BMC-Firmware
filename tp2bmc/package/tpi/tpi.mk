###########################################################
# turing pi CLI
###########################################################
TPI_VERSION:= 68ec911a4c06b6debf784cdadd792112e9f6ca56
TPI_SITE = $(call github,excavador-turing,tpi,$(TPI_VERSION))
TPI_LICENSE = Apache-2.0
TPI_LICENSE_FILES = LICENSE
# native-tls means openssl-sys, which links the target libopenssl through
# pkg-config. The sequential build satisfied that by accident (bmcd had
# built libopenssl earlier); the top-level parallel build (per-package
# directories) failed on it at 2026-09-07 00:56: "The system library
# `openssl` required by crate `openssl-sys` was not found". Declare it.
TPI_DEPENDENCIES = host-pkgconf libopenssl
TPI_CARGO_ENV := PKG_CONFIG_ALLOW_CROSS=1
TPI_CARGO_INSTALL_OPTS = --features localhost,native-tls

$(eval $(cargo-package))
