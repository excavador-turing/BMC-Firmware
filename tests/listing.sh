#!/bin/sh
#
# A firmware listing that FAILED must not look like an empty one.
#
# `tpi-selfupdate --list` prints one JSON line that bmcd turns into the
# firmware page's catalogue. When it could not reach the source it used to
# print `{"releases":[]}` and exit 0, with the real reason on stderr where
# nothing read it -- because `die` inside `list_releases` exits the subshell
# of a pipeline, not the script, and the array had already been opened.
#
# What that looked like on a board: no DNS, so every remote source came back
# with nothing and no error, and the page said there was no update. Reported
# from a 2.4 board on 2026-09-22 ("checking github for updated firmware also
# fails silently"), then reproduced on board B -- `curl: (6) Could not
# resolve host: api.github.com` on stderr, a well-formed empty listing on
# stdout, exit 0.
#
# Every case here stubs `curl` on PATH: no network, no board, no flash.
#
# Run:  sh tests/listing.sh
#
set -u

SCRIPT=${SCRIPT:-tp2bmc/board/tp2bmc/overlay/sbin/tpi-selfupdate}
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
bin="$work/bin"
mkdir -p "$bin"

# The board reads its running version from here; the script refuses without
# it, and that refusal is not what these cases are about.
osrelease="$work/os-release"
printf 'VERSION="v2.35.0"\n' > "$osrelease"

# curl, stubbed. $STUB_MODE picks what it does:
#   fail    -- what a board with no resolver gets: exit 6, message on stderr
#   ok      -- a small but valid GitHub releases body
cat > "$bin/curl" <<'STUB'
#!/bin/sh
case "${STUB_MODE:-fail}" in
	fail)
		echo "curl: (6) Could not resolve host: api.github.com" >&2
		exit 6
		;;
	ok)
		printf '[{"tag_name":"v2.36.0","draft":false,"prerelease":false},'
		printf '{"tag_name":"v2.35.0","draft":false,"prerelease":false}]'
		exit 0
		;;
esac
STUB
chmod +x "$bin/curl"

run() {
	# $1 is STUB_MODE; the rest are the script's arguments. stdout and stderr
	# are kept apart, because the whole point is which one carries what.
	mode=$1
	shift
	STUB_MODE="$mode" PATH="$bin:$PATH" OS_RELEASE="$osrelease" \
		sh "$SCRIPT" "$@" > "$work/out" 2> "$work/err"
	echo $?
}

echo "1. a listing that could not be fetched"
status=$(run fail --list --repo excavador-turing/BMC-Firmware)
[ "$status" -ne 0 ] \
	&& ok "exits non-zero ($status)" \
	|| bad "exited 0 on a source it could not reach"
[ ! -s "$work/out" ] \
	&& ok "prints nothing on stdout" \
	|| bad "printed a listing anyway: $(cat "$work/out")"
grep -q "releases" "$work/out" 2>/dev/null \
	&& bad "printed an empty releases array, which reads as 'nothing new'" \
	|| ok "no empty releases array"
grep -qi "could not resolve\|cannot reach" "$work/err" \
	&& ok "says why, on stderr" \
	|| bad "silent about the reason: $(cat "$work/err")"

echo "2. the same, for an http source"
status=$(run fail --list --url https://firmware.example/bmc)
[ "$status" -ne 0 ] \
	&& ok "exits non-zero ($status)" \
	|| bad "exited 0 on a URL it could not reach"
[ ! -s "$work/out" ] \
	&& ok "prints nothing on stdout" \
	|| bad "printed a listing anyway: $(cat "$work/out")"

echo "3. a listing that worked still works"
status=$(run ok --list --repo excavador-turing/BMC-Firmware)
[ "$status" -eq 0 ] \
	&& ok "exits 0" \
	|| bad "exited $status on a source it could read: $(cat "$work/err")"
head -1 "$work/out" | grep -q '^{.*"releases":\[' \
	&& ok "prints one JSON line" \
	|| bad "did not print a listing: $(cat "$work/out")"
grep -q '"tag":"v2.36.0"' "$work/out" \
	&& ok "carries the releases it was given" \
	|| bad "lost the releases: $(cat "$work/out")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
