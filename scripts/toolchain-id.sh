#!/bin/sh
# shellcheck shell=sh
#
# The identity of the cross-toolchain: a hash of everything that decides
# what `make toolchain` produces, and nothing else. It names the prebuilt
# toolchain image (ghcr.io/<owner>/bmc-toolchain:tc-<id>), so a change to
# any input builds a new image and an unchanged toolchain is never rebuilt.
#
# Inputs, and why each is one:
#   Dockerfile               the host compiler and libc the toolchain's own
#                            binaries link against; a different base image
#                            is a different toolchain binary
#   Dockerfile.toolchain     how the SDK is placed in the image
#   scripts/configure.sh     the Buildroot release, which pins gcc, binutils,
#                            glibc and the headers series
#   scripts/toolchain-sdk.sh how the SDK is built and packaged
#   buildroot_patches/*      anything that could change the above
#   the defconfig, filtered  architecture and toolchain symbols only. A
#                            package added to the image does not change
#                            the compiler, and must not rebuild it
#   the CI fragment          what the consumer will assert about it
#
# Run from the repository root. Prints one line: 16 hex characters.
set -eu
cd "$(dirname "$0")/.."
{
	cat Dockerfile Dockerfile.toolchain scripts/configure.sh scripts/toolchain-sdk.sh
	cat buildroot_patches/* 2>/dev/null || true
	# arch symbols are lowercase (BR2_arm, BR2_cortex_a7); the rest by name
	grep -E '^BR2_([a-z]|ARM_|TOOLCHAIN|GCC|BINUTILS|GLIBC|KERNEL_HEADERS|PACKAGE_HOST_LINUX_HEADERS|STATIC_LIBS|SHARED|CCACHE)' \
		tp2bmc/configs/tp2bmc_defconfig
	cat tp2bmc/configs/ci-external-toolchain.fragment
} | sha256sum | cut -c1-16
