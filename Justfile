# Local build loop for the BMC firmware.
#
# The build itself runs in the same container CI uses, so a local result and
# a CI result come from the same toolchain. What differs is the machine: a
# workstation has an order of magnitude more cores than a hosted runner, and
# an incremental kernel rebuild takes a couple of minutes against a 23-minute
# CI round trip. Iterate here, push when it builds.
#
# Everything a build creates is gitignored: buildroot/ dl/ .ccache/ dist/
# .home/. Files stay owned by you -- the container runs as your uid, unlike
# CI, which runs as root and needs a chown before it can cache anything.

image_tag := "buildroot_local:latest"
release := "local"

# UBI slot the image is written into: 370 LEBs of 126976 B. genimage.cfg
# calls the same number 45880K, and osupdate's NEWVOL_LEBS must agree.
slot_bytes := "46981120"

# The sibling repositories, read-only at /src, so `BMCD_OVERRIDE_SRCDIR` and
# `BMC_UI_OVERRIDE_SRCDIR` in buildroot/local.mk can point at a working tree
# that is being edited rather than at a copy.
#
# Without this the container mounts only this repository, so an override
# naming a path on the host fails with "does not exist" from inside -- which
# is what happens if you write the host path you can see in your shell.
# Point overrides at /src/bmcd and /src/BMC-UI.
#
# Read-only on purpose: Buildroot rsyncs OUT of the override into
# <pkg>-custom and builds there, so nothing needs to write back, and a build
# container that cannot touch your source cannot corrupt it.
_docker := "docker run --rm -v \"$PWD:/work\" -v \"$PWD/..:/src:ro\" -w /work --user \"$(id -u):$(id -g)\" -e HOME=/work/.home -e BR2_DL_DIR=/work/dl -e BR2_CCACHE_DIR=/work/.ccache -e CCACHE_MAXSIZE=2G " + image_tag

default:
    @just --list

# Build the container CI builds. Cached; seconds after the first run.
container:
    docker build -t {{image_tag}} .

# Unpack Buildroot and apply buildroot_patches/. DESTRUCTIVE: it deletes and
# re-extracts buildroot/, so run it once, then use `just build` or `just kernel`.
configure: container
    mkdir -p .home
    {{_docker}} /work/scripts/configure.sh

# Full build. Run `just configure` first if buildroot/ is not there yet.
build: container
    mkdir -p .home
    {{_docker}} /work/scripts/build.sh --release {{release}}
    @just size

# Kernel patches are applied when the source is extracted, so an edit to
# tp2bmc/patches/linux/* needs a dirclean before it is seen at all.
#
# The patch loop: rebuild the kernel, repack the images. Minutes, not a CI round trip.
kernel: container
    {{_docker}} sh -c 'cd /work/buildroot && make linux-dirclean linux-rebuild && make'
    @just size

# A shell in the build container, at the repo root.
shell: container
    {{_docker}} bash

# The number the build is judged by. CI fails at 90 %; this only reports.
size:
    #!/usr/bin/env bash
    set -euo pipefail
    img=buildroot/output/images/rootfs.erofs
    if [ ! -f "$img" ]; then echo "no image yet: $img"; exit 0; fi
    bytes=$(stat -c%s "$img")
    printf 'rootfs: %s bytes, %s%% of the %s byte UBI slot (%s KB free)\n' \
        "$bytes" "$((bytes * 100 / {{slot_bytes}}))" "{{slot_bytes}}" \
        "$((({{slot_bytes}} - bytes) / 1024))"

# What is actually in the image, biggest first -- decide by bytes, not by guess.
biggest count="25":
    #!/usr/bin/env bash
    set -euo pipefail
    t=buildroot/output/target
    [ -d "$t" ] || { echo "no target tree yet; run a build first"; exit 0; }
    find "$t" -type f -exec du -k {} + | sort -rn | head -{{count}}

# Lint what the container lints, without waiting for CI.
lint: container
    {{_docker}} sh -c 'shellcheck scripts/*.sh tp2bmc/board/tp2bmc/overlay/sbin/mount_overlay || true; hadolint Dockerfile'

# Drop the build tree, keep the caches (`git clean -xfd` would throw those away).
clean:
    rm -rf buildroot dist .home
