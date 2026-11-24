###########################################################
# turing pi CLI
###########################################################
TPI_VERSION:= 61f83d190b6ef670e23c2d376aa2de1b0ffd0f74
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

# The size of what was installed, in the build log: the only place a change to
# the build profile shows up as a number before a board is flashed.
define TPI_LOG_INSTALLED_SIZE
	echo "installed size: $$(stat -c %s $(TARGET_DIR)/usr/bin/tpi) bytes, /usr/bin/tpi"
endef
TPI_POST_INSTALL_TARGET_HOOKS += TPI_LOG_INSTALLED_SIZE

$(eval $(cargo-package))
