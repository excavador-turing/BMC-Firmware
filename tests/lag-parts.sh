#!/bin/sh
#
# What the hardware LAG (LACP uplink) needs from the image, checked offline.
#
# A bond on this board only works if four things line up, and none of them
# fails loudly on its own: a build with a patch missing from the series still
# builds, a kernel without bonding still boots, and a boot with the default
# bond0 still gets an address -- the bond just never has the mode, hash policy
# or members it was configured with. This reads each of them from the tree so a
# change that drops one fails at review instead of on a board.
#
# Run:  sh tests/lag-parts.sh
#
# shellcheck disable=SC2015  # ok/bad never fail, so `A && ok || bad` is if/else
set -u
cd "$(dirname "$0")/.." || exit 1
DEFCONFIG=tp2bmc/configs/tp2bmc_defconfig
KCONFIG=tp2bmc/board/tp2bmc/linux_defconfig
BOOTSCR=tp2bmc/board/tp2bmc/boot.scr
PATCHES=tp2bmc/patches/linux
MANIFEST=$PATCHES/series.manifest
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

echo "1. the kernel can bond"
grep -qE '^CONFIG_BONDING=y$' $KCONFIG && ok "CONFIG_BONDING=y" \
	|| bad "$KCONFIG must set CONFIG_BONDING=y (built in: the bond executor runs 'ip link add type bond', no modprobe)"

echo "2. no bond0 before ifupdown makes it"
# Built-in bonding creates bond0 at boot unless told otherwise, and
# ifupdown-ng's bond executor skips a bond that already exists, so the
# configured mode, hash policy and members would never be applied.
grep -E '^[[:space:]]*setenv bootargs ' $BOOTSCR | grep -q 'bonding\.max_bonds=0' && ok "bonding.max_bonds=0 on the kernel command line" \
	|| bad "$BOOTSCR must pass bonding.max_bonds=0 in the bootargs"

echo "3. ifupdown-ng and iproute2 are in the image"
grep -qE '^BR2_PACKAGE_IFUPDOWN_NG=y$' $DEFCONFIG && ok "ifupdown-ng (installs the bond executor)" \
	|| bad "$DEFCONFIG must enable BR2_PACKAGE_IFUPDOWN_NG"
grep -qE '^BR2_PACKAGE_IPROUTE2=y$' $DEFCONFIG && ok "iproute2 (the executor calls ip link add type bond)" \
	|| bad "$DEFCONFIG must enable BR2_PACKAGE_IPROUTE2"

echo "4. the hardware LAG patches are in the series, in order"
# The manifest is documentation Buildroot never reads, so it can only be kept
# honest by comparing it with what BR2_LINUX_KERNEL_PATCH really applies: the
# listed directories in order, each one's *.patch in name order.
dirs=$(sed -n 's/^BR2_LINUX_KERNEL_PATCH="\(.*\)"$/\1/p' $DEFCONFIG | sed 's|\$(BR2_EXTERNAL_TP2BMC_PATH)/patches/linux/||g')
if [ -z "$dirs" ]; then
	bad "$DEFCONFIG names no BR2_LINUX_KERNEL_PATCH directories"
else
	applied=$(for d in $dirs; do for f in "$PATCHES/$d"/*.patch; do printf '%s\n' "${f#"$PATCHES"/}"; done; done)
	listed=$(grep -v '^#' $MANIFEST | grep -v '^$')
	if [ "$applied" = "$listed" ]; then
		ok "series.manifest lists exactly what the defconfig applies ($(printf '%s\n' "$applied" | wc -l) patches)"
	else
		bad "series.manifest and the patches the defconfig applies differ:"
		printf '%s\n' "$applied" > "${TMPDIR:-/tmp}/lag-applied.$$"
		printf '%s\n' "$listed" > "${TMPDIR:-/tmp}/lag-listed.$$"
		diff "${TMPDIR:-/tmp}/lag-applied.$$" "${TMPDIR:-/tmp}/lag-listed.$$" | sed 's/^/       /'
		rm -f "${TMPDIR:-/tmp}/lag-applied.$$" "${TMPDIR:-/tmp}/lag-listed.$$"
	fi
	# The three LAG patches come before the FDB keying fix, the order they
	# were built and tested in.
	for want in net-dsa/0014-net-dsa-rtl8365mb-add-hardware-LAG-trunk-offload.patch \
	            net-dsa/0015-net-dsa-rtl8365mb-LAG-bridge-uplink-VLAN-sync-fixups.patch \
	            net-dsa/0016-net-dsa-rtl8365mb-LAG-PHY-autoneg-kick.patch; do
		printf '%s\n' "$applied" | grep -qxF "$want" && ok "applies $want" || bad "the series does not apply $want"
	done
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
