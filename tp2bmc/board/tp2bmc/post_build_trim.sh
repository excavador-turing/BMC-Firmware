#!/bin/sh
# Drop OpenSSH programs the image does not use. Buildroot installs the
# client, the server and the key utils as three groups, and the groups
# cannot be split further. ssh, scp, sftp, ssh-keygen, sshd and
# sftp-server stay.
set -eu

: "${TARGET_DIR:?}"

rm -f \
	"${TARGET_DIR}/usr/bin/ssh-agent" \
	"${TARGET_DIR}/usr/bin/ssh-add" \
	"${TARGET_DIR}/usr/libexec/ssh-keysign" \
	"${TARGET_DIR}/usr/libexec/ssh-pkcs11-helper" \
	"${TARGET_DIR}/usr/bin/ssh-copy-id" \
	"${TARGET_DIR}/usr/bin/ssh-keyscan" \
	"${TARGET_DIR}/etc/ssh/moduli"
