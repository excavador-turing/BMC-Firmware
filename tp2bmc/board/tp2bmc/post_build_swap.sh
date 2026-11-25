#!/bin/sh
# CONFIG_SWAP is off. Buildroot's sysv skeleton still runs swapon and
# swapoff from /etc/inittab, and those lines fail the boot.
set -eu

: "${TARGET_DIR:?}"

inittab="${TARGET_DIR}/etc/inittab"
if [ -f "${inittab}" ]; then
	sed -i -e '/swapon/d' -e '/swapoff/d' "${inittab}"
fi
