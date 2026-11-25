#!/bin/sh
# mkfs.ubifs selects BR2_PACKAGE_LIBOPENSSL_ENGINES, so Buildroot still
# installs engine files. Dynamic loading is off. Drop whatever .so files
# remain, and the legacy provider, which is where the weak algorithms live.
set -eu

: "${TARGET_DIR:?}"

rm -rf "${TARGET_DIR}/usr/lib/engines-3"
rm -f "${TARGET_DIR}/usr/lib/ossl-modules/legacy.so"
rmdir "${TARGET_DIR}/usr/lib/ossl-modules" 2>/dev/null || true
