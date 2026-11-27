#!/bin/sh
# Modules are built in, so /lib/modules is not installed. Buildroot's
# S10mdev still coldplugs with modprobe after it prints OK, and
# mdev.conf still runs modprobe for a MODALIAS. Both print
# "can't change directory to '/lib/modules'".
set -eu

: "${TARGET_DIR:?}"

mdev_init="${TARGET_DIR}/etc/init.d/S10mdev"
if [ -f "${mdev_init}" ]; then
	sed -i '/# coldplug modules/,/modprobe -abq/d' "${mdev_init}"
fi

mdev_conf="${TARGET_DIR}/etc/mdev.conf"
if [ -f "${mdev_conf}" ]; then
	sed -i '/\$MODALIAS=.*modprobe/d' "${mdev_conf}"
fi
