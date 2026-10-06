###########################################################
#
# bmc_installer
#
###########################################################

# Pinned to the fork's keep-settings branch until its PR merges; then
# re-pinned to the merge commit on master.
BMC_INSTALLER_VERSION = 266192b9016978f22ddc5e3a14287bcb2abfa6ce
BMC_INSTALLER_SITE = $(call github,excavador-turing,BMC-Installer,$(BMC_INSTALLER_VERSION))
BMC_INSTALLER_LICENSE = Apache-2.0
BMC_INSTALLER_LICENSE_FILES = LICENSE
BMC_INSTALLER_INSTALL_STAGING = YES
BMC_INSTALLER_INSTALL_TARGET = NO
BMC_INSTALLER_CARGO_BUILD_OPTS = --bin=sdcard --bin=sdcard_userspace

define BMC_INSTALLER_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0755 $(@D)/target/$(RUSTC_TARGET_NAME)/$(if $(BR2_ENABLE_DEBUG),debug,release)/sdcard $(STAGING_DIR)/initramfs/install/init
	$(INSTALL) -D -m 0755 $(@D)/target/$(RUSTC_TARGET_NAME)/$(if $(BR2_ENABLE_DEBUG),debug,release)/sdcard_userspace $(BINARIES_DIR)/factory_overlay/upper/factory/install_firmware
endef

$(eval $(cargo-package))
