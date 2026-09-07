#!/usr/bin/env bash
# shellcheck shell=bash

# This script downloads, unpacks and installs the buildroot system to a given
# location. The default install location will be used when no install dir is
# passed, this is the root directory of this repository.
#
# Usage:
#
#   ./setup_build.sh <install dir> (optional)
#

# Configure shell
set -eo pipefail

# Buildroot Version.
#
# 2025.02.x is the current long-term-support series (Buildroot maintains one
# LTS a year for ~12 months past the next release); 2024.05.1 stopped getting
# fixes in 2024 and its toolchain and package set have been unmaintained
# since. .17 is the newest point release of the series.
BUILDROOT_VER="2025.02.17"
# From the signed https://buildroot.org/downloads/buildroot-2025.02.17.tar.gz.sign
BUILDROOT_SHA256="622d32d9f277f3c4681f046dda425057db61552db65957c0990d258ecad3b2c1"

# Save current directory
CWD=$(pwd)

download_dir=$(mktemp -d)
buildroot_url="https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.gz"
buildroot=$(basename "$buildroot_url")
buildroot_folder="${buildroot%.tar.gz}"
buildroot_target="buildroot"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"

# Function to display usage
usage() {
    echo "Usage: $0 [--dir|-d <directory>] [--release|-r] [--help|-h]"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir|-i)
            if [[ -n "$2" ]]; then
                install_dir="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --target|-t)
            if [[ -n "$2" ]]; then
                buildroot_target="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --help|-h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

printf 'Configure:\n'
printf '  Buildroot Version: %s\n' "$BUILDROOT_VER"
printf '  Install Directory: %s\n' "$install_dir"
printf '  Target Directory:  %s\n' "$buildroot_target"

pushd "$download_dir"
    wget "$buildroot_url"
    echo "${BUILDROOT_SHA256}  ${buildroot}" | sha256sum -c -
    # No -v: the listing is ~20k lines of noise in every CI log.
    tar -xf "$buildroot"
popd

if [ -z "$install_dir" ]; then
    # try to install it into the base-dir of the git repo
    install_dir="$project_root"
else
    mkdir -p "$install_dir"
fi

if [ -e "$install_dir/$buildroot_target" ]; then
    rm -rf "$install_dir/${buildroot_target:?}/"
fi

mv "$download_dir/$buildroot_folder" "$install_dir/$buildroot_target"

pushd "$install_dir/$buildroot_target"
for patchfile in "$project_root"/buildroot_patches/*; do
    if [ -f "$patchfile" ]; then
        patch -p1 < "$patchfile"
    fi
done
popd

# Restore current directory
cd "${CWD}" || exit 1
