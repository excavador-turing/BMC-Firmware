#!/bin/sh
# shellcheck shell=sh
#
# The certificate the board serves when nobody has given it a real one.
#
# A BMC is reachable before it is enrolled in anything, so it has to be able
# to speak TLS on its own. That certificate is not a formality: it is what
# protects the password typed into the login page on the management LAN, which
# is the break-glass path and the whole reason the board keeps its own
# interface.
#
# What upstream's version did, and why each part was a problem:
#
#   openssl req -x509 -newkey rsa:4096 -nodes -subj "/CN=Turing-Pi self signed"
#
#   * NO subjectAltName. Every browser since 2017 matches the name against the
#     SAN and ignores the common name entirely, so that certificate could not
#     be accepted by any of them -- not even by clicking through, in some, and
#     never by a tool that checks properly. A self-signed certificate nobody
#     can choose to trust is decoration.
#   * No -days, so openssl's default of 30 applies, and the script only ever
#     regenerated when a file was MISSING. A board left running served an
#     expired certificate for as long as it stayed up. One in this estate did
#     exactly that for over a year (SQU-115).
#   * RSA 4096 on a board with ~87 MB of usable RAM, for a key that protects a
#     LAN login. P-384 is stronger per bit, faster to generate and far smaller.
#   * The pair check used `openssl rsa -noout -modulus`, which fails on any key
#     that is not RSA. An operator who installs an EC or Ed25519 certificate
#     lands in the branch that DELETES BOTH FILES and regenerates. A script
#     that can destroy the operator's certificate is worse than one that does
#     nothing.
#
# This version:
#
#   * names the board in the SAN -- hostname, .local, and every address it
#     currently holds -- so the certificate can actually be trusted
#   * sets an expiry and RENEWS BEFORE IT ARRIVES, so a board that stays up
#     does not start serving an expired certificate
#   * uses EC P-384, the estate's standing key type
#   * compares PUBLIC KEYS, which works for RSA, EC and Ed25519 alike
#   * NEVER touches a certificate it did not issue. Anything whose issuer is
#     not this script's own subject is somebody's real certificate and is left
#     exactly where it is, expired or not. Saying so loudly and changing
#     nothing is the correct behaviour for a script that cannot tell why.
#
# Run at boot by S94bmcd when either file is missing, and safe to run at any
# other time: it decides what is needed and does only that.

set -eu

# Overridable only so the behaviour below can be tested without a board. The
# board never sets it, and nothing reads it at runtime.
ssl_dir=${BMCD_SSL_DIR:-/etc/ssl/certs}
cert_file="${ssl_dir}/bmcd_cert.pem"
key_file="${ssl_dir}/bmcd_key.pem"

# The subject this script issues under. It is also the marker used to decide
# whether a certificate on disk is ours to replace, so it must not change
# casually: a board upgraded to a version with a different subject would treat
# its own previous certificate as an operator's and stop renewing it.
self_subject="/CN=Turing Pi BMC self-signed"

# 825 days is the longest a publicly trusted certificate may be valid and a
# sensible ceiling for a self-signed one too. Renewal starts 30 days out, so a
# board that is up for years never serves an expired certificate and a board
# that is off for a month does not come back to one either.
days_valid=825
renew_within_days=30

log() { echo "generate_self_signedx509: $*"; }

# Every name and address a client might legitimately use to reach this board.
#
# The IPs come from the interfaces as they are NOW, which is the honest answer
# and also the limitation: a board whose address changes needs a new
# certificate. That is why renewal exists on a timer rather than only at first
# boot, and why `bmc-cert` in the estate's own tooling replaces this with a
# CA-issued one carrying the address deliberately.
build_san() {
    host=$(hostname 2>/dev/null || echo turingpi)
    san="DNS:${host},DNS:${host}.local,DNS:localhost"

    # Addresses, skipping loopback and link-local: a certificate asserting
    # 169.254.x or ::1 tells a client nothing it can use.
    for addr in $(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
        case "$addr" in
            127.*|::1|fe80:*) continue ;;
        esac
        san="${san},IP:${addr}"
    done
    echo "$san"
}

generate() {
    log "issuing a new self-signed certificate for $(build_san)"
    mkdir -p "${ssl_dir}"

    tmp_key="${key_file}.new.$$"
    tmp_cert="${cert_file}.new.$$"
    # Written under a temporary name and moved into place, so a daemon reading
    # mid-write never sees half a file, and a failure leaves the previous pair
    # untouched rather than a board with no certificate at all.
    trap 'rm -f "${tmp_key}" "${tmp_cert}"' EXIT

    openssl req -x509 \
        -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 \
        -keyout "${tmp_key}" -out "${tmp_cert}" \
        -days "${days_valid}" -nodes \
        -subj "${self_subject}" \
        -addext "subjectAltName=$(build_san)" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" \
        >/dev/null 2>&1

    chmod 600 "${tmp_key}"
    chmod 644 "${tmp_cert}"
    mv "${tmp_key}" "${key_file}"
    mv "${tmp_cert}" "${cert_file}"
    sync
    trap - EXIT
    log "done; valid for ${days_valid} days"
}

# True when the certificate on disk was issued by this script. Compared on the
# issuer, not the subject: a CA-issued certificate can carry any subject at
# all, but its issuer is the CA.
is_ours() {
    issuer=$(openssl x509 -in "${cert_file}" -noout -issuer 2>/dev/null || echo "")
    # `-issuer` prints "issuer=CN = Turing Pi BMC self-signed" with spacing
    # that has varied between openssl releases, so compare on the name alone.
    echo "$issuer" | grep -q "Turing Pi BMC self-signed"
}

# True when the certificate and the private key are two halves of one pair.
# Public keys, not moduli: a modulus exists only for RSA, and asking for one
# from an EC key is what made the old script delete working certificates.
pair_matches() {
    from_cert=$(openssl x509 -in "${cert_file}" -noout -pubkey 2>/dev/null || echo "cert-unreadable")
    from_key=$(openssl pkey -in "${key_file}" -pubout 2>/dev/null || echo "key-unreadable")
    [ "$from_cert" = "$from_key" ] && [ "$from_cert" != "cert-unreadable" ]
}

# True when the certificate is still valid for at least the renewal window.
still_fresh() {
    openssl x509 -in "${cert_file}" -noout \
        -checkend "$((renew_within_days * 86400))" >/dev/null 2>&1
}

if [ ! -s "${cert_file}" ] || [ ! -s "${key_file}" ]; then
    log "no certificate on disk"
    generate
    exit 0
fi

if ! is_ours; then
    # The operator's certificate. Report what is wrong and change nothing:
    # replacing a CA-issued certificate with a self-signed one would turn a
    # working deployment into a browser warning, silently, at boot.
    if ! still_fresh; then
        log "WARNING: the installed certificate expires within ${renew_within_days} days" \
            "or has already expired -- it was not issued here, so it is left alone."
        log "  $(openssl x509 -in "${cert_file}" -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"
    else
        log "an operator's certificate is installed; leaving it alone"
    fi
    exit 0
fi

if ! pair_matches; then
    log "our certificate and key do not belong together; reissuing"
    generate
    exit 0
fi

if ! still_fresh; then
    log "our certificate expires within ${renew_within_days} days; reissuing"
    generate
    exit 0
fi

log "our certificate is present, paired and current"
exit 0
