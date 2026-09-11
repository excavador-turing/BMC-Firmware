#!/usr/bin/env bash
# What generate_self_signedx509.sh must do, and must never do.
#
# The board's own certificate is what protects the password typed into the
# login page on the management LAN. Upstream's version of that script produced
# a certificate with NO subjectAltName -- unusable by any browser since 2017 --
# valid for 30 days, never renewed, and with a pair check that DELETED an
# operator's certificate if it was not RSA.
#
# So the interesting cases here are the destructive ones. Case 3 and case 4
# are the regression tests: a certificate this script did not issue must come
# out the other side byte for byte.
#
# Runs anywhere with openssl; the script takes its directory from BMCD_SSL_DIR
# so nothing here touches /etc.
set -uo pipefail
SCRIPT="${1:-tp2bmc/package/bmcd/generate_self_signedx509.sh}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export BMCD_SSL_DIR="$work"
C="$work/bmcd_cert.pem"; K="$work/bmcd_key.pem"
fp() { openssl x509 -in "$C" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

echo "1. an empty directory"
out=$(sh "$SCRIPT" 2>&1)
[ -s "$C" ] && [ -s "$K" ] && ok "issues a pair" || bad "issues a pair: $out"
san=$(openssl x509 -in "$C" -noout -ext subjectAltName 2>/dev/null | tr -d ' \n')
echo "$san" | grep -q "DNS:" && ok "carries a SAN (the old one had none)" || bad "carries a SAN: '$san'"
# openssl PRINTS the extension as IPAddress:, though it is written as IP:
echo "$san" | grep -q "IPAddress:" && ok "names an address" || bad "names an address: $san"
openssl x509 -in "$C" -noout -text 2>/dev/null | grep -q "secp384r1\|P-384" && ok "is EC P-384" || bad "is EC P-384"
openssl x509 -in "$C" -noout -checkend $((800*86400)) >/dev/null 2>&1 && ok "valid well beyond 30 days" || bad "valid beyond 30 days"
openssl x509 -in "$C" -noout -text 2>/dev/null | grep -q "TLS Web Server Authentication" && ok "is marked for server auth" || bad "server auth EKU"
[ "$(stat -c %a "$K")" = "600" ] && ok "the key is not world-readable" || bad "key mode is $(stat -c %a "$K")"

echo "2. run again"
first=$(fp); sh "$SCRIPT" >/dev/null 2>&1
[ "$(fp)" = "$first" ] && ok "leaves a good certificate alone" || bad "reissued needlessly"

echo "3. an operator's certificate from some other CA"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes \
  -subj "/CN=bmc-1.haarlem.lan" -days 1 -keyout "$K" -out "$C" >/dev/null 2>&1
theirs=$(fp)
out=$(sh "$SCRIPT" 2>&1)
[ "$(fp)" = "$theirs" ] && ok "never replaces a certificate it did not issue" || bad "DESTROYED the operator's certificate"
echo "$out" | grep -qi "expires within\|leaving it alone" && ok "says something about it" || bad "silent: $out"

echo "4. an operator's EC certificate that the OLD script would have deleted"
# The old pair check ran `openssl rsa -noout -modulus`, which fails on EC.
openssl rsa -noout -modulus -in "$K" >/dev/null 2>&1 && bad "the key is RSA, wrong fixture" || ok "the fixture is a non-RSA key"
sh "$SCRIPT" >/dev/null 2>&1
[ "$(fp)" = "$theirs" ] && ok "survives the pair check" || bad "pair check ate it"

echo "5. our own certificate, expiring soon"
rm -f "$C" "$K"; sh "$SCRIPT" >/dev/null 2>&1
subj=$(openssl x509 -in "$C" -noout -subject)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes \
  -subj "/CN=Turing Pi BMC self-signed" -days 5 -keyout "$K" -out "$C" >/dev/null 2>&1
old=$(fp); sh "$SCRIPT" >/dev/null 2>&1
[ "$(fp)" != "$old" ] && ok "renews before it expires" || bad "did not renew a 5-day certificate"
openssl x509 -in "$C" -noout -checkend $((800*86400)) >/dev/null 2>&1 && ok "the replacement is long-lived" || bad "replacement is short"

echo "6. our certificate with a key that is not its own"
openssl ecparam -genkey -name secp384r1 -out "$K" >/dev/null 2>&1
old=$(fp); sh "$SCRIPT" >/dev/null 2>&1
[ "$(fp)" != "$old" ] && ok "reissues a mismatched pair" || bad "kept a mismatched pair"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
