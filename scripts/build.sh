#!/usr/bin/env bash
# shellcheck shell=bash

set -eo pipefail

# Save current directory
CWD=$(pwd)

# Configure directories
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
dist="${root}/dist"
build_root="${root}/buildroot"
release="$(date +'%Y.%m.%d'-"$(git rev-parse --short=8 HEAD)")"
package=""

# Function to display usage
usage() {
    echo "Usage: $0 [--dir|-d <directory>] [--release|-r] [--package|-p] [--help|-h]"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir|-d)
            if [[ -n "$2" ]]; then
                build_root="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --release|-r)
            if [[ -n "$2" ]]; then
                release="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --help|-h)
            usage
            ;;
        --package|-p)
            if [[ -n "$2" ]]; then
                package="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        *)
            usage
            ;;
    esac
done

# EXPORT the version so it reaches post_build.sh.
#
# Upstream PR #242 adds an overwrite_os_release() hook to
# tp2bmc/board/tp2bmc/post_build.sh that reads $BUILD_VERSION from the
# ENVIRONMENT. Nothing sets it: this script parses --release into the local
# `release` and uses it only for output filenames, and the CI workflow passes
# it as a CLI argument, not an env var. post_build.sh runs under
# `set -euo pipefail`, so the unset variable is fatal:
#
#   post_build.sh: line 25: BUILD_VERSION: unbound variable
#   make: *** [Makefile:755: target-finalize] Error 1
#
# at target-finalize -- after ~100 minutes of building. Exporting here makes
# the value flow through make to the hook by every invocation path, while
# still honouring a BUILD_VERSION set by the caller.
export BUILD_VERSION="${BUILD_VERSION:-$release}"

# Jump to build directory
cd "${build_root}" || exit 1

# Prepare buildroot
make BR2_EXTERNAL=../tp2bmc tp2bmc_defconfig

# Top-level parallel build: with BR2_PER_PACKAGE_DIRECTORIES=y in the
# defconfig, independent packages build concurrently; without -j here that
# option buys nothing. Per-package -j stays at Buildroot's default (nproc+1).
cmd=(make -j"$(nproc)")
if [[ -n "$package" ]]; then
    echo "Building Package: $package"
    cmd+=("$package")
fi

# Build
if "${cmd[@]}"; then
    if [[ -n "$package" ]]; then
        echo "Building package completed"
        exit 0
    fi
    OTA_FILENAME="tp2-bmc-firmware-ota-${release}.tpu"
    SDCARD_FILENAME="tp2-bmc-firmware-sdcard-${release}.img"

    # Check if we are running on darwin (macOS)
    # if we do then use the mounted dist folder, this is the repository directory on the host
    if [[ "${HOST_OS^^}" == "DARWIN" ]]; then
        dist="/mnt/dist"
    fi

    # Create dist folder if not exists
    if [[ ! -d "${dist}" ]]; then
        mkdir -p "${dist}"
    fi

    printf '\n\n'
    printf '================================================================================\n'
    printf 'Build Completed\n\n'

    # Copy to dist folder
    if [[ -d "${build_root}/output/images" ]]; then
        # Check for OTA Image
        if [[ -f "${build_root}/output/images/rootfs.erofs" ]]; then
            # The rootfs is written verbatim into a fixed-size static UBI
            # volume by `osupdate` (370 LEBs of 126976 B; genimage.cfg calls
            # the same thing 45880K). Nothing upstream warns before it stops
            # fitting -- `ubiupdatevol` just fails on the board, after the
            # download, with the old slot already cleaned away. So measure it
            # here, print it every run, and fail the build at 90 %.
            rootfs_bytes=$(stat -c%s "${build_root}/output/images/rootfs.erofs")
            slot_bytes=$((370 * 126976))
            slot_pct=$((rootfs_bytes * 100 / slot_bytes))
            printf 'rootfs: %s bytes, %s%% of the %s byte UBI slot\n' \
                "${rootfs_bytes}" "${slot_pct}" "${slot_bytes}"
            if [[ "${slot_pct}" -ge 90 ]]; then
                echo "Error: rootfs is ${slot_pct}% of the UBI slot (limit 90%)." >&2
                echo "       Drop something from tp2bmc_defconfig, or raise the" >&2
                echo "       slot in genimage.cfg AND osupdate's NEWVOL_LEBS." >&2
                exit 1
            fi

            # OTA image exists, copy it to dist
            echo "Copying OTA image"
            cp -v "${build_root}/output/images/rootfs.erofs" "${dist}/${OTA_FILENAME}"
            
            # The image is a binary image therefor use sha256sum binary mode
            echo "Generating SHA256 for: ${OTA_FILENAME}.sha256"
            sha256sum -b "${dist}/${OTA_FILENAME}" > "${dist}/${OTA_FILENAME}.sha256"
        else
            echo "Error: OTA image not found"
        fi

        # Check for SDCard image
        if [[ -f "${build_root}/output/images/tp2-bmc-firmware-sdcard.img" ]]; then
            # SDCard image, copy it to dist
            echo "Copying SDCard image"
            cp -v "${build_root}/output/images/tp2-bmc-firmware-sdcard.img" "${dist}/${SDCARD_FILENAME}"

            # The image is a binary image therefor use sha256sum binary mode
            echo "Generating SHA256 for: ${SDCARD_FILENAME}"
            sha256sum -b "${dist}/${SDCARD_FILENAME}" > "${dist}/${SDCARD_FILENAME}.sha256"
        else
            echo "Error: SDCard image not found"
        fi
    fi

    # If on macOS sync to Host
    if [[ "${HOST_OS^^}" == "DARWIN" ]]; then
        "${root}/scripts/sync.sh"
    fi

    # Summary
    printf '\n\n'
    printf '================================================================================\n'
    printf 'Summary\n\n'

    printf "%s\n\n" "$(du -h "${dist}/${OTA_FILENAME}" "${dist}/${SDCARD_FILENAME}")"
else
    # A FAILING BUILD MUST FAIL THE SCRIPT. `if make; then ... fi` with no else
    # swallows make's exit code: this script returns 0, CI marks the build step
    # green, and the only symptom is `mv: cannot stat 'dist'` two steps later --
    # a confusing error a long way from its cause.
    #
    # That is exactly how the 2026-09-06 bmcd v2.3.7 virtual-manifest failure
    # presented: 115 minutes of building, a green step, and no artifacts.
    printf '\n\nBUILD FAILED -- make exited non-zero; no images were produced.\n' >&2
    exit 1
fi

# Restore current directory
cd "${CWD}" || exit 1
