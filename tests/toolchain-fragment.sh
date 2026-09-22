#!/bin/sh
#
# The CI fragment states what the prebuilt toolchain IS; the toolchain is
# built from the defconfig. If the two disagree, Buildroot refuses the
# toolchain at configure time -- twelve minutes into a run, after the
# toolchain job has already built and pushed an image for it. This reads
# the same facts from the defconfig, offline, so a stale fragment fails at
# review instead.
#
# Run:  sh tests/toolchain-fragment.sh
#
# shellcheck disable=SC2015  # ok/bad never fail, so `A && ok || bad` is if/else
set -u
cd "$(dirname "$0")/.." || exit 1
DEFCONFIG=tp2bmc/configs/tp2bmc_defconfig
FRAGMENT=tp2bmc/configs/ci-external-toolchain.fragment
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
set_in()   { grep -qE "^$2=y$" "$1"; }
unset_in() { grep -qE "^# $2 is not set$" "$1" || ! grep -qE "^$2=" "$1"; }

echo "1. what the defconfig builds, the fragment must declare"
gcc=$(sed -n 's/^BR2_GCC_VERSION_\([0-9]*\)_X=y$/\1/p' $DEFCONFIG)
if [ -z "$gcc" ]; then
	bad "the defconfig names no gcc version; name it (BR2_GCC_VERSION_NN_X=y) so this can be checked"
else
	set_in $FRAGMENT "BR2_TOOLCHAIN_EXTERNAL_GCC_$gcc" && ok "gcc $gcc" || bad "defconfig builds gcc $gcc; fragment does not say GCC_$gcc"
fi
if set_in $DEFCONFIG BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_12; then
	set_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL_HEADERS_6_12 && ok "headers 6.12" || bad "defconfig uses 6.12 headers; fragment does not say HEADERS_6_12"
fi
if set_in $DEFCONFIG BR2_TOOLCHAIN_BUILDROOT_GLIBC || ! grep -qE '^BR2_TOOLCHAIN_BUILDROOT_(UCLIBC|MUSL)=y' $DEFCONFIG; then
	set_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL_CUSTOM_GLIBC && ok "glibc" || bad "defconfig builds glibc; fragment does not say CUSTOM_GLIBC"
fi
if set_in $DEFCONFIG BR2_ARM_EABIHF; then
	grep -q 'CUSTOM_PREFIX="arm-buildroot-linux-gnueabihf"' $FRAGMENT && ok "prefix gnueabihf" || bad "defconfig is EABIhf; the prefix must end in gnueabihf"
else
	grep -q 'CUSTOM_PREFIX="arm-buildroot-linux-gnueabi"' $FRAGMENT && ok "prefix gnueabi (soft-float ABI)" || bad "defconfig is EABI; the prefix must end in gnueabi"
fi
if set_in $DEFCONFIG BR2_TOOLCHAIN_BUILDROOT_CXX; then
	set_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL_CXX && ok "C++" || bad "defconfig enables C++; fragment does not say CXX"
else
	unset_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL_CXX && ok "no C++" || bad "defconfig builds no C++; fragment claims CXX"
fi
if set_in $DEFCONFIG BR2_TOOLCHAIN_BUILDROOT_LOCALE; then
	set_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL_LOCALE && ok "locale" || bad "defconfig enables locale; fragment does not say LOCALE"
else
	unset_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL_LOCALE && ok "no locale" || bad "defconfig builds no locale; fragment claims LOCALE"
fi

echo "2. what the fragment must always say"
set_in $FRAGMENT BR2_TOOLCHAIN_EXTERNAL && ok "external" || bad "BR2_TOOLCHAIN_EXTERNAL=y missing"
grep -qE '^# BR2_TOOLCHAIN_BUILDROOT is not set$' $FRAGMENT && ok "internal toolchain off" || bad "BR2_TOOLCHAIN_BUILDROOT must be unset"
grep -qE '^# BR2_TOOLCHAIN_EXTERNAL_INET_RPC is not set$' $FRAGMENT && ok "RPC unset (glibc has none)" || bad "INET_RPC must be unset or Buildroot refuses the toolchain"
grep -qE '^BR2_TOOLCHAIN_EXTERNAL_PATH="/opt/sdk"$' $FRAGMENT && ok "path /opt/sdk" || bad "PATH must be /opt/sdk, where Dockerfile.toolchain unpacks it"

echo "3. the identity covers the fragment"
grep -q "ci-external-toolchain.fragment" scripts/toolchain-id.sh && ok "toolchain-id hashes the fragment" || bad "scripts/toolchain-id.sh must hash the fragment"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
