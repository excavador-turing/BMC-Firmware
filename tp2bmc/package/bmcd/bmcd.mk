###########################################################
#
# bmcd
###########################################################

BMCD_VERSION = 4d0aa5187fe6f8a7e5440ef80e6c8c498aa70c1a
BMCD_SITE = $(call github,excavador,bmcd,$(BMCD_VERSION))
BMCD_LICENSE = Apache-2.0
BMCD_LICENSE_FILES = LICENSE
# host-pkgconf explicitly: with per-package directories only declared
# dependencies' host tools are visible to this package's build.
BMCD_DEPENDENCIES += host-pkgconf libopenssl
BMCD_CARGO_ENV := PKG_CONFIG_ALLOW_CROSS=1
BMCD_CARGO_ENV += CC_armv7_unknown_linux_gnueabi="arm-linux-gcc"

# A copy of the default build commands with --path amended, because bmcd's
# root Cargo.toml is a VIRTUAL manifest from v2.3.5 onward: `feat: split
# board_info into seperate package` turned the repo into a workspace of
# {bmcd, board_info}, and `cargo install --path ./` on a workspace root
# fails with
#
#   error: found a virtual manifest at .../Cargo.toml instead of a package manifest
#
# Upstream master carries this same comment while still pinning v2.3.4, which
# has a real package manifest -- so `--path ./` works there and the comment is
# aspirational. Upstream PR #242 bumps the version to v2.3.7 WITHOUT amending
# the path, which is why it does not build. Plausibly why it has sat unmerged
# since 2025-02-23.
define BMCD_INSTALL_TARGET_CMDS
	cd $(BMCD_SRCDIR) && \
	$(TARGET_MAKE_ENV) \
		$(PKG_CARGO_ENV) \
		$(BMCD_CARGO_ENV) \
		cargo install \
			--offline \
			--root $(TARGET_DIR)/usr/ \
			--bins \
			--path ./bmcd \
			--force \
			--locked \
			-Z target-applies-to-host \
			$(BMCD_CARGO_INSTALL_OPTS)

	$(INSTALL) -D -m 744 $(BR2_EXTERNAL_TP2BMC_PATH)/package/bmcd/generate_self_signedx509.sh \
		$(TARGET_DIR)/etc/bmcd/generate_self_signedx509.sh

	$(INSTALL) -D -m 755 $(BMCD_SRCDIR)/default_config.yaml \
		$(TARGET_DIR)/etc/bmcd/config.yaml
endef

define BMCD_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 755 $(BR2_EXTERNAL_TP2BMC_PATH)/package/bmcd/S94bmcd \
		$(TARGET_DIR)/etc/init.d/S94bmcd
endef

$(eval $(cargo-package))
