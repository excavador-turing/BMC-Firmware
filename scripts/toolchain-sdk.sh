#!/usr/bin/env bash
# shellcheck shell=bash
#
# Build the cross-toolchain and package it as a relocatable SDK, for the
# prebuilt toolchain image. Runs INSIDE the build container after
# configure.sh, like build.sh does; writes sdk-toolchain.tar.gz at the
# repository root.
#
# This is Buildroot's own `prepare-sdk` recipe (Makefile) run by hand,
# because that recipe depends on `world` -- the whole firmware -- and a
# toolchain-only SDK is all the consumer needs: the build that uses it
# still builds every host tool and target package itself, with the
# compiler taken from /opt/sdk. Measured 2026-09-22: 85 MB, against several
# hundred for the full SDK.
#
# With BR2_PER_PACKAGE_DIRECTORIES there is no assembled output/host until
# `world`; the toolchain's own per-package host tree holds the toolchain and
# everything it depends on, which is exactly the set to ship.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
cd "${root}/buildroot"

make BR2_EXTERNAL=../tp2bmc tp2bmc_defconfig
make -j"$(nproc)" toolchain host-ccache

host_dir="${root}/buildroot/output/per-package/toolchain/host"
[ -d "${host_dir}" ] || host_dir="${root}/buildroot/output/host"
[ -x "${host_dir}/bin/arm-buildroot-linux-gnueabi-gcc" ] \
	|| { echo "no cross gcc under ${host_dir}" >&2; exit 1; }

install -m 755 support/misc/relocate-sdk.sh "${host_dir}/relocate-sdk.sh"
mkdir -p "${host_dir}/share/buildroot"
(
	export LC_ALL=C
	grep -lr "${host_dir}" "${host_dir}" | while read -r f; do
		if file -b --mime-type "$f" | grep -q '^text/' \
			&& [ "$f" != "${host_dir}/share/buildroot/sdk-location" ] \
			&& [ "$f" != "${host_dir}/share/buildroot/sdk-relocs" ]; then
			echo "$f"
		fi
	done
) | sed -e "s|^${host_dir}|.|g" > "${host_dir}/share/buildroot/sdk-relocs"
echo "${host_dir}" > "${host_dir}/share/buildroot/sdk-location"

# The tarball's single top-level directory is `sdk`, so it unpacks under
# /opt as /opt/sdk, which is the path the CI fragment names.
tar -czf "${root}/sdk-toolchain.tar.gz" --owner=0 --group=0 --numeric-owner \
	--transform="s#^${host_dir#/}#sdk#" -C / "${host_dir#/}"
ls -la "${root}/sdk-toolchain.tar.gz"
"${host_dir}/bin/arm-buildroot-linux-gnueabi-gcc" --version | head -1
