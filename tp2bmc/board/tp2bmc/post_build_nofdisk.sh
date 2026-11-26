#!/bin/sh
# util-linux's basic set installs fdisk and sfdisk together, and there
# is no separate switch. sfdisk is the GPT tool. fdisk is the extra binary.
set -eu

: "${TARGET_DIR:?}"

rm -f "${TARGET_DIR}/sbin/fdisk" "${TARGET_DIR}/usr/sbin/fdisk" "${TARGET_DIR}/usr/bin/fdisk"
