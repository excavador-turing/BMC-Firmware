#!/bin/sh
#
# Contract tests for the promotion gate in S99postupdate.
#
# The gate decides whether a freshly booted image is kept or rejected. It is
# the most consequential shell on the board, and until this file existed
# nothing checked it: a change could ship that promoted everything, and the
# only way to find out was a flash.
#
# The gate was written to be testable -- every path it reads is a variable,
# never a literal -- so this harness sources the script, points those
# variables at scratch files, stubs curl, and calls release_matches()
# directly. No board, no network, no root.
#
# THE POINT OF THE THREE FAILING CASES: a gate that cannot say no is not a
# gate. Most of these assert a rejection.
#
# Run:  sh tests/gate.sh          (busybox ash on the board, or any POSIX sh)
#
set -u

SCRIPT=${SCRIPT:-tp2bmc/board/tp2bmc/overlay/etc/init.d/S99postupdate}

if [ ! -f "$SCRIPT" ]; then
	echo "cannot find $SCRIPT -- run this from the repository root" >&2
	exit 2
fi

# Sourcing is safe: the file ends in a `case "$1"` that matches only "start"
# and "force". Give it a $1 that matches neither -- unset would trip `set -u`
# in the sourced file. Nothing runs; we get the functions.
set -- harness
# shellcheck disable=SC1090
. "./$SCRIPT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Redirect every path the gate reads. These assignments are the whole reason
# the gate declares them as variables.
LOGFILE="$WORK/postupdate.log"
STAGED_NOTE="$WORK/staged-firmware"
OS_RELEASE="$WORK/os-release"
CURL_BIN="$WORK/curl"

# The URL the gate is REQUIRED to request. Deliberately a literal, and
# deliberately not assigned to the gate's own METRICS_URL: overriding that
# would make the stub follow the script wherever it went, so a gate that
# quietly returned to :443 would still pass. This is the one value in this
# file that must not track the thing it is testing.
EXPECT_METRICS_URL="http://127.0.0.1:9110/metrics"

PASS=0
FAIL=0

#
# stub_curl METRICS_BEHAVIOUR
#
# Writes a fake curl that answers the gate's one request. Behaviours:
#
#   "ok" (a body containing bmcd_build_info), "empty" (a 200 with an
#   unrelated body -- the broken-build case), or "dead" (exit 7, as a daemon
#   that is not listening at all).
#
# It takes one argument now. The gate used to make two requests: mint a
# metrics token through /api/bmc, then present it to /metrics. /metrics moved
# to its own plain listener and takes no credential, so both the token
# behaviour and the stub arm that served it are gone.
#
# It is a real executable on a real path, so the gate's `[ -x ]` check and
# its argument handling are exercised, not bypassed. It answers only
# $EXPECT_METRICS_URL, so the port the gate asks for is part of the contract
# this file tests rather than something it inherits.
#
stub_curl() {
	cat >"$CURL_BIN" <<STUB
#!/bin/sh
for arg in "\$@"; do
	case "\$arg" in
		$EXPECT_METRICS_URL)
			case "$1" in
				ok)    printf 'bmcd_build_info{version="v2.8.0"} 1\n'; exit 0 ;;
				empty) printf 'some_other_metric 1\n'; exit 0 ;;
				dead)  exit 7 ;;
			esac
			;;
	esac
done
exit 0
STUB
	chmod +x "$CURL_BIN"
}

#
# check NAME EXPECTED_RC EXPECTED_LOG_SUBSTRING
#
# Runs the gate against whatever the caller just staged and asserts both the
# verdict and the reason. Asserting the log too is deliberate: a gate that
# rejects for the wrong reason is a gate that will reject the wrong image.
#
check() {
	name=$1
	want_rc=$2
	want_log=$3

	: >"$LOGFILE"
	if release_matches >/dev/null 2>&1; then rc=0; else rc=1; fi

	if [ "$rc" -ne "$want_rc" ]; then
		printf 'FAIL  %s\n        expected rc=%s, got rc=%s\n' "$name" "$want_rc" "$rc"
		sed 's/^/        | /' "$LOGFILE"
		FAIL=$((FAIL + 1))
		return
	fi
	if ! grep -q "$want_log" "$LOGFILE"; then
		printf 'FAIL  %s\n        rc=%s as expected, but the log never said "%s"\n' \
			"$name" "$rc" "$want_log"
		sed 's/^/        | /' "$LOGFILE"
		FAIL=$((FAIL + 1))
		return
	fi
	if [ "$want_rc" -eq 0 ]; then verdict=PASS; else verdict='PASS  (rejected, as it must)'; fi
	printf '%s  %s\n' "$verdict" "$name"
	PASS=$((PASS + 1))
}

running_is() { printf 'ID=tp2bmc\nVERSION=%s\n' "$1" >"$OS_RELEASE"; }
note_says()  { printf '%s\n' "$1" >"$STAGED_NOTE"; }
no_note()    { rm -f "$STAGED_NOTE"; }

echo "gate contract tests -- $SCRIPT"
echo

# --- the happy path ------------------------------------------------------
running_is v2.8.0
note_says 'VERSION=v2.8.0'
stub_curl ok
check 'note v2.8.0, image v2.8.0' 0 'version matches the staged note'

# --- the rejection this gate exists for ----------------------------------
# Proven on hardware 2026-09-09: the note tampered to v0.0.1 rolled the board
# back to v2.8.0 with exactly this line in postupdate.log.
running_is v2.8.0
note_says 'VERSION=v2.7.0'
check 'note v2.7.0, image v2.8.0' 1 'FAILED: staged v2.7.0 but this image reports v2.8.0'

# --- a note the upload path wrote for an unversioned file ----------------
# write_staged_note() emits FILE=/STAGED_AT=/SOURCE= always, and VERSION=
# only when the file name yields a tag. No version is not a mismatch.
running_is v2.8.0
note_says 'FILE=some-hand-built-image.tpu
STAGED_AT=2026-09-08T23:28:50Z
SOURCE=upload'
check 'note names a FILE but no VERSION' 0 'staged note carries no version'

# --- a dev build ---------------------------------------------------------
running_is v2.8.0
note_says 'VERSION=local'
check "dev build 'local'" 0 "carries no version"

# --- no note at all ------------------------------------------------------
# A first boot, or a note already cleared. Skip the comparison; still demand
# metrics, because there is nothing else vouching for this image.
running_is v2.8.0
no_note
check 'no staged note' 0 'no staged note'

# --- the daemon is up but its metrics are broken -------------------------
# The whole reason for the second half: both earlier checks pass here.
running_is v2.8.0
note_says 'VERSION=v2.8.0'
stub_curl empty
check 'daemon answers without bmcd_build_info' 1 'FAILED: /metrics did not answer'

# --- the daemon does not answer /metrics at all --------------------------
stub_curl dead
check 'daemon does not answer /metrics' 1 'FAILED: /metrics did not answer'

# --- the endpoint answers with the wrong body ----------------------------
# A build whose /metrics serves something, but not this daemon's own
# families, is exactly what the first two checks would wave through.
running_is v2.8.0
note_says 'VERSION=v2.8.0'
stub_curl empty
check 'metrics answers, but not with bmcd_build_info' 1 'FAILED: /metrics did not answer'

# --- no curl on the board ------------------------------------------------
# Not a hypothetical: a rootfs-headroom change could drop it. The version
# half still has to run, and the metrics half must be skipped with a reason
# rather than failing an otherwise good image.
running_is v2.8.0
note_says 'VERSION=v2.8.0'
CURL_BIN="$WORK/no-such-curl"
check 'no curl present' 0 'no curl; metrics check skipped'
CURL_BIN="$WORK/curl"

# --- exactly as it runs on the board today -------------------------------
running_is v2.8.1-rc1
note_says 'VERSION=v2.8.1-rc1
FILE=tp2-bmc-firmware-ota-v2.8.1-rc1.tpu
STAGED_AT=2026-09-08T23:32:57Z
SOURCE=upload'
stub_curl ok
check 'the board, as it stands' 0 'version matches the staged note: v2.8.1-rc1'

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
