###########################################################
#
# bmc-ui
###########################################################

BMC_UI_VERSION = v3.32.0
BMC_UI_SITE = https://github.com/excavador-turing/BMC-UI/releases/download/$(BMC_UI_VERSION)
BMC_UI_LICENSE = GPL-2.0
BMC_UI_LICENSE_FILES = LICENSE
# The tree is replaced, not added to. A release build starts from an empty
# target, so this never mattered there; the local loop does not, and every
# override build left its hashed bundles beside the last one's -- nine
# index-*.js on 2026-09-21, 4.5 MB of them, and a rootfs over its slot.
define BMC_UI_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/srv/bmcd/www
	mkdir -p $(TARGET_DIR)/srv/bmcd/www/
	cp -r $(BMC_UI_SRCDIR)* $(TARGET_DIR)/srv/bmcd/www/
	chmod 755 $(TARGET_DIR)/srv/bmcd/www/
endef

$(eval $(generic-package))
