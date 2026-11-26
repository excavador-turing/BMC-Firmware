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
SYS_NET="$WORK/sys-net"
SYS_I2C="$WORK/sys-i2c"
GATEWAY_NOTE="$WORK/staged-gateway"
PING_BIN="$WORK/ping"
# Read by the sourced gate, which shellcheck cannot see.
# shellcheck disable=SC2034
STAGE_LOCK="$WORK/firmware-stage.lock"
# shellcheck disable=SC2034
FW_PRINTENV_BIN="$WORK/fw_printenv"
# shellcheck disable=SC2034
PROC_CMDLINE="$WORK/cmdline"
# Two seconds of retrying, not sixty: the loop is the same, the test is not slow.
# Both are read by the sourced gate, which shellcheck cannot see.
# shellcheck disable=SC2034
GATEWAY_TIMEOUT=2
# shellcheck disable=SC2034
GATEWAY_INTERVAL=1

# The marker the gate reads to tell "an interrupted fork staging" from "another
# firmware's installer", and the sysfs directory that says which volume is which.
RUNNING_IMAGE_NOTE="$WORK/running-image"
# Read by the sourced gate, which shellcheck cannot see.
# shellcheck disable=SC2034
UBI_SYS="$WORK/sys-ubi"

# The stager writes what the gate reads, so the harness runs it too, against
# stubs of `ip` and `ping` and a scratch note.
STAGER=${STAGER:-tp2bmc/board/tp2bmc/overlay/sbin/stage-gateway-note}

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
# check NAME EXPECTED_RC EXPECTED_LOG_SUBSTRING [FUNCTION]
#
# FUNCTION is the gate function to run; release_matches when left out. An
# empty EXPECTED_LOG_SUBSTRING asserts the verdict only, for the checks that
# say nothing when they pass.
#
# Runs the gate against whatever the caller just staged and asserts both the
# verdict and the reason. Asserting the log too is deliberate: a gate that
# rejects for the wrong reason is a gate that will reject the wrong image.
#
check() {
	name=$1
	want_rc=$2
	want_log=$3
	fn=${4:-release_matches}

	: >"$LOGFILE"
	if "$fn" >/dev/null 2>&1; then rc=0; else rc=1; fi

	if [ "$rc" -ne "$want_rc" ]; then
		printf 'FAIL  %s\n        expected rc=%s, got rc=%s\n' "$name" "$want_rc" "$rc"
		sed 's/^/        | /' "$LOGFILE"
		FAIL=$((FAIL + 1))
		return
	fi
	if [ -n "$want_log" ] && ! grep -q "$want_log" "$LOGFILE"; then
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

# assert NAME COMMAND...: PASS when the command succeeds.
assert() {
	name=$1; shift
	if "$@"; then
		printf 'PASS  %s\n' "$name"; PASS=$((PASS + 1))
	else
		printf 'FAIL  %s\n' "$name"; FAIL=$((FAIL + 1))
	fi
}

# Assertions about what the gate logged, on the check that ran last.
wrote() { grep -q "$1" "$LOGFILE"; }
no_failure_logged() { ! grep -q FAILED "$LOGFILE"; }

# Scratch stand-in for /sys/class/ubi/ubi0: ubi_vol NAME ID BYTES makes volume
# ubi0_ID. The "rootfs" volume is the image a tentative boot replaces.
ubi_reset() { rm -rf "$UBI_SYS"; mkdir -p "$UBI_SYS/ubi0"; }
ubi_vol() {
	mkdir -p "$UBI_SYS/ubi0/ubi0_$2"
	printf '%s\n' "$1" >"$UBI_SYS/ubi0/ubi0_$2/name"
	printf '%s\n' "$3" >"$UBI_SYS/ubi0/ubi0_$2/data_bytes"
}
# The old image is this firmware: it recorded itself at volume ubi0_1.
fork_was_running() {
	ubi_reset; ubi_vol rootfs 1 23990272; ubi_vol rootfs_new 2 24000000
	printf 'IMAGE=ubi0_1:23990272\nVERSION=v2.57.0\n' >"$RUNNING_IMAGE_NOTE"
}
# The old image is stock firmware: same volumes, and no marker anywhere.
stock_was_running() {
	ubi_reset; ubi_vol rootfs 1 23990272; ubi_vol rootfs_new 2 24000000
	rm -f "$RUNNING_IMAGE_NOTE"
}

running_is() { printf 'ID=tp2bmc\nVERSION=%s\n' "$1" >"$OS_RELEASE"; }
note_says()  { printf '%s\n' "$1" >"$STAGED_NOTE"; }
no_note()    { rm -f "$STAGED_NOTE"; }

# Scratch stand-ins for /sys/class/net and /sys/bus/i2c/devices. Interfaces
# are directories; an EEPROM is a file; a bound RTC is a directory with a
# `driver` entry. A real board's carrier state never enters into it, which is
# the point of the uplink cases.
net_ports() { rm -rf "$SYS_NET"; mkdir -p "$SYS_NET"; for p in "$@"; do mkdir "$SYS_NET/$p"; done; }
i2c_reset() { rm -rf "$SYS_I2C"; mkdir -p "$SYS_I2C"; }
eeprom_ok() { mkdir -p "$SYS_I2C/2-0050"; dd if=/dev/zero bs=256 count=1 2>/dev/null | tr '\0' '\377' >"$SYS_I2C/2-0050/eeprom"; }
eeprom_empty() { mkdir -p "$SYS_I2C/2-0050"; : >"$SYS_I2C/2-0050/eeprom"; }
rtc_with_driver() { mkdir -p "$SYS_I2C/2-0051"; : >"$SYS_I2C/2-0051/driver"; }
rtc_without_driver() { mkdir -p "$SYS_I2C/2-0051"; rm -f "$SYS_I2C/2-0051/driver"; }

#
# stub_ping BEHAVIOUR
#
# A fake ping that insists on the arguments the gate and the stager are
# contracted to use (`-c 2 -W 2 <address>`) and answers for 10.0.0.1 only:
#   "up"      always answers
#   "down"    never answers
#   "late"    stays silent for the first two calls, then answers (a link that
#             comes up while the gate is retrying)
# Anything else exits 2, so a changed argument list fails the test.
#
stub_ping() {
	rm -f "$WORK/ping.calls"
	cat >"$PING_BIN" <<STUB
#!/bin/sh
[ "\$*" = "-c 2 -W 2 10.0.0.1" ] || exit 2
echo x >>"$WORK/ping.calls"
case "$1" in
	up) exit 0 ;;
	down) exit 1 ;;
	late) [ "\$(wc -l <"$WORK/ping.calls")" -gt 2 ] && exit 0; exit 1 ;;
esac
STUB
	chmod +x "$PING_BIN"
}

gateway_note_says() { printf '%s\n' "$1" >"$GATEWAY_NOTE"; }
no_gateway_note()   { rm -f "$GATEWAY_NOTE"; }

# A fake `ip` that prints a routing table, and insists on being asked for the
# IPv4 default route.
stub_ip() {
	cat >"$WORK/ip" <<STUB
#!/bin/sh
[ "\$*" = "-4 route show default" ] || exit 2
printf '%s' "$1"
STUB
	chmod +x "$WORK/ip"
}

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

# --- no note at all, asked of release_matches alone ----------------------
# release_matches no longer decides what a missing note means: notes_present
# does, below, and runs first. Reached with no note, it is a board with no
# overlay to hold one: skip the comparison, still demand metrics.
running_is v2.8.0
no_note
check 'no staged note, version comparison alone' 0 'no staged note'

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

# --- the switch and its uplinks -----------------------------------------
# The ports are directories under SYS_NET. There is no carrier in this
# fixture at all, and none is asked for: an uplink with no cable must pass.
net_ports node1 node2 node3 node4 ge0 ge1
check 'all four node ports present' 0 '' switch_ports_present
check 'ge0 and ge1 present, no carrier anywhere' 0 '' uplinks_present

net_ports node1 node2 node3 node4
check 'ge0 and ge1 missing' 1 'FAILED: uplink port ge0 does not exist' uplinks_present
net_ports node1 node2 node3 node4 ge0
check 'ge1 missing' 1 'FAILED: uplink port ge1 does not exist' uplinks_present
net_ports node1 node2 node3 ge0 ge1
check 'node4 missing' 1 'FAILED: switch port node4 does not exist' switch_ports_present

# --- the EEPROM ----------------------------------------------------------
i2c_reset
eeprom_ok
check 'EEPROM answers' 0 'EEPROM readable' eeprom_readable

i2c_reset
eeprom_empty
check 'EEPROM returns no data' 1 'FAILED: EEPROM .* returned no data' eeprom_readable

i2c_reset
check 'no EEPROM exposed at all' 1 'FAILED: no EEPROM is exposed' eeprom_readable

# --- the RTC -------------------------------------------------------------
i2c_reset
rtc_with_driver
check 'RTC declared and bound' 0 'RTC driver bound' rtc_bound

i2c_reset
rtc_without_driver
check 'RTC declared, driver did not bind' 1 'FAILED: the RTC at .* has no driver' rtc_bound

i2c_reset
check 'no RTC declared (a board without one)' 0 'RTC check skipped' rtc_bound

# --- the gateway ---------------------------------------------------------
# The stager records a gateway that answered; the gate then requires it to
# answer again on the tentative boot, retrying while the link comes up.
stub_ping up
gateway_note_says 'GATEWAY=10.0.0.1
GATEWAY_PING=ok'
check 'recorded gateway still answers' 0 'gateway 10.0.0.1 answers' gateway_reachable

stub_ping late
check 'gateway answers after a few retries' 0 'gateway 10.0.0.1 answers' gateway_reachable

stub_ping down
check 'gateway answered before and no longer does' 1 'FAILED: gateway 10.0.0.1 answered before the update' gateway_reachable

# Nothing recorded, or nothing that answered: never block such a board, even
# though ping would fail here.
gateway_note_says 'GATEWAY=10.0.0.1
GATEWAY_PING=none'
check 'gateway never answered before: skipped' 0 'gateway check skipped' gateway_reachable
gateway_note_says 'GATEWAY_PING=none'
check 'no gateway recorded: skipped' 0 'gateway check skipped' gateway_reachable
no_gateway_note
check 'no gateway note at all (an old stager): skipped' 0 'gateway check skipped' gateway_reachable
gateway_note_says 'GATEWAY=not-an-address
GATEWAY_PING=ok'
check 'gateway note names no address: skipped' 0 'not an address' gateway_reachable

# The whole gate, end to end: everything local is good, and the verdict then
# turns on the gateway alone. bmcd_answers is replaced, because there is no
# daemon on a CI runner; every other check runs for real.
bmcd_answers() { return 0; }
running_is v2.8.0
note_says 'VERSION=v2.8.0'
stub_curl ok
net_ports node1 node2 node3 node4 ge0 ge1
i2c_reset; eeprom_ok; rtc_with_driver
gateway_note_says 'GATEWAY=10.0.0.1
GATEWAY_PING=ok'
stub_ping up
check 'the whole gate, gateway answers' 0 'gateway 10.0.0.1 answers' health_ok
stub_ping down
check 'the whole gate, gateway silent: rejected' 1 'FAILED: gateway 10.0.0.1' health_ok
no_gateway_note
check 'the whole gate, no gateway note: promoted' 0 'gateway check skipped' health_ok

# --- missing notes are a rejection ----------------------------------------
# The stagers write the notes before they arm nextboot, so a tentative boot
# with none is an interrupted staging (BMC-Firmware#126). It used to log
# "no staged note; version check skipped" and promote.
running_is v2.8.0
note_says 'VERSION=v2.8.0'
no_gateway_note
check 'staged note present' 0 '' notes_present

fork_was_running
no_note
check 'no staged note on a tentative boot: rejected' 1 'FAILED: no staged note on a tentative boot' notes_present

# --- ... unless the image being replaced is not this firmware ----------------
# Found on hardware 2026-11-26: the stock installer writes rootfs_new and arms
# nextboot and writes none of our notes, so the first boot of this fork on a
# stock board has no staged note and never will. That is not an interrupted
# staging, and rejecting it made the fork impossible to install.
stock_was_running
no_note
check 'stock firmware was running (no marker): accepted, and says why' 0 'is not this firmware (it recorded no marker)' notes_present
assert 'and the log does not call it a failure' no_failure_logged

# A marker left by an earlier stay of this firmware, on a board that has since
# been through stock: the volume it names is gone, so it vouches for nothing.
fork_was_running; ubi_reset; ubi_vol rootfs 3 11111111; ubi_vol rootfs_new 2 24000000
no_note
check 'a stale marker (fork, then stock, now installing the fork again): accepted' 0 'the marker is for ubi0_1:23990272 and rootfs is ubi0_3:11111111' notes_present

# Same volume id, different image: the id alone would have vouched for it.
fork_was_running; ubi_reset; ubi_vol rootfs 1 11111111; ubi_vol rootfs_new 2 24000000
no_note
check 'a stale marker with a reused volume id: accepted' 0 'is not this firmware' notes_present

# The marker matches: the old image was this firmware, so no note is the
# interrupted staging #126 is about, however many other things look alike.
fork_was_running
no_note
check 'fork to fork, no staged note: still rejected' 1 'FAILED: no staged note on a tentative boot' notes_present

# A marker that exists but cannot be compared is not read as "another firmware".
fork_was_running; rm -f "$UBI_SYS/ubi0/ubi0_1/data_bytes"
no_note
check 'a marker and an unreadable volume size: rejected (errs towards the gate)' 1 'FAILED: no staged note on a tentative boot' notes_present

# postupdate.log is no signal: a failed attempt leaves it behind.
stock_was_running
no_note
printf 'Wed postupdate: FAILED: no staged note on a tentative boot\n' >"$LOGFILE"
check 'a log from an earlier failed attempt does not make it a fork' 0 'is not this firmware' notes_present
fork_was_running

saved_note=$STAGED_NOTE
STAGED_NOTE="$WORK/no-overlay/staged-firmware"
check 'no overlay at all: the note check is skipped' 0 'note check is skipped' notes_present
STAGED_NOTE=$saved_note

# A staged note that says the gateway note came first, and the gateway note is
# gone: an interrupted staging, or a note removed behind its back.
note_says 'VERSION=v2.8.0
GATE_NOTES=1'
no_gateway_note
check 'the note promises a gateway note that is not there: rejected' 1 'FAILED: the staged note says the gateway note was written first' notes_present
gateway_note_says 'GATEWAY_PING=none'
check 'the note promises a gateway note and it is there' 0 '' notes_present

# A note from a stager that never promised one keeps the old leniency, or the
# first update FROM an older firmware would be rolled back for ever on a board
# with no default route.
note_says 'VERSION=v2.8.0'
no_gateway_note
check 'an older stager recorded no gateway note: accepted' 0 '' notes_present

# The whole gate: everything local good, and the verdict turns on the note.
no_note
check 'the whole gate, no staged note: rejected before anything is asked' 1 'FAILED: no staged note on a tentative boot' health_ok
note_says 'VERSION=v2.8.0'
check 'the whole gate, staged note present: promoted' 0 'version matches the staged note' health_ok

# The migration, end to end: nothing staged, nothing recorded, and every check
# that does not need a note still runs.
stock_was_running
no_note; no_gateway_note
check 'the whole gate, from stock: promoted, version and gateway checks skipped' 0 'gateway check skipped' health_ok
assert 'and it said the version check was skipped' wrote 'no staged note; version check skipped'
stub_curl empty
check 'the whole gate, from stock, /metrics broken: still rejected' 1 'FAILED: /metrics did not answer' health_ok
stub_curl ok
fork_was_running
no_note; no_gateway_note
check 'the whole gate, fork to fork with no note: rejected' 1 'FAILED: no staged note on a tentative boot' health_ok
note_says 'VERSION=v2.8.0'

# --- a boot that is not tentative: stale notes are discarded --------------
# U-Boot deletes nextboot before it boots the staged volume. A power cut
# during that tentative boot leaves the old image running with nextboot unset
# and the notes still on disk (BMC-Firmware#131).
stub_printenv() {
	cat >"$FW_PRINTENV_BIN" <<STUB
#!/bin/sh
case "$1" in
	armed) echo 'bootmode=postupdate; distro_bootpart=rootfs_new; run boot_do_scan'; exit 0 ;;
	unset) echo '## Error: "nextboot" not defined' >&2; exit 1 ;;
	unreadable) echo 'Cannot read environment, using default' >&2; exit 1 ;;
esac
STUB
	chmod +x "$FW_PRINTENV_BIN"
}
notes_exist() { [ -e "$STAGED_NOTE" ] || [ -e "$GATEWAY_NOTE" ]; }
no_notes_left() { [ ! -e "$STAGED_NOTE" ] && [ ! -e "$GATEWAY_NOTE" ]; }
stage_two_notes() {
	note_says 'VERSION=v2.57.0
SOURCE=tpi-selfupdate'
	gateway_note_says 'GATEWAY=10.0.0.1
GATEWAY_PING=ok'
}

stage_two_notes; stub_printenv unset
check 'nextboot unset: the stale notes are discarded' 0 'tentative boot did not complete; staged v2.57.0 discarded' drop_unarmed_notes
assert 'both notes are gone' no_notes_left

stage_two_notes; stub_printenv armed
check 'nextboot armed: the notes are kept' 0 '' drop_unarmed_notes
assert 'both notes are still there' notes_exist

stage_two_notes; stub_printenv unreadable
check 'the environment cannot be read: the notes are kept' 0 '' drop_unarmed_notes
assert 'both notes are still there (unknown is not unset)' notes_exist

stage_two_notes; stub_printenv unset
no_note
check 'only a gateway note is left: it goes, with its own words' 0 'staging did not finish; the stale gateway note is discarded' drop_unarmed_notes
assert 'the gateway note is gone' no_notes_left

# A stager that is mid-write holds the lock, has written its notes, and has not
# armed nextboot yet. Its notes are not ours to remove.
stage_two_notes; stub_printenv unset
( exec 9>"$STAGE_LOCK"; flock -n 9 && sleep 3 ) &
holder=$!
sleep 1
check 'a stager holds the staging lock: the notes are left' 0 'a stager holds the staging lock' drop_unarmed_notes
assert 'both notes are still there while the lock is held' notes_exist
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check 'the lock is released: they go' 0 'tentative boot did not complete' drop_unarmed_notes
assert 'both notes are gone once the lock is free' no_notes_left

# start(), the whole decision tree. The volume functions read /sys, which a CI
# runner does not have, and rollback/postupdate reboot and rename; the harness
# replaces those four and runs everything else for real.
ubi_exists() { return 0; }
ubi_block_name() { echo "$STUB_BLOCK"; }
rollback() { ROLLED=1; }
postupdate() { PROMOTED=1; }
run_start() {
	ROLLED=0; PROMOTED=0
	: >"$LOGFILE"
	start >/dev/null 2>&1
}
good_image() {
	bmcd_answers() { return 0; }
	running_is v2.57.0
	stub_curl ok
	net_ports node1 node2 node3 node4 ge0 ge1
	i2c_reset; eeprom_ok; rtc_with_driver
	stub_ping up
}
good_image

echo 'quiet splash' >"$PROC_CMDLINE"; STUB_BLOCK=rootfs
stage_two_notes; stub_printenv unset
run_start
assert 'a normal boot with nextboot unset: the notes are dropped and it says so' no_notes_left
assert 'and the decision is in the log' wrote 'tentative boot did not complete; staged v2.57.0 discarded'
assert 'and nothing was rolled back or promoted' [ "$ROLLED$PROMOTED" = 00 ]

echo 'quiet postupdate' >"$PROC_CMDLINE"; STUB_BLOCK=rootfs_new
stage_two_notes; stub_printenv unset
gateway_note_says 'GATEWAY=10.0.0.1
GATEWAY_PING=ok'
note_says 'VERSION=v2.57.0
GATE_NOTES=1'
run_start
assert 'a tentative boot with its notes: promoted' [ "$PROMOTED" = 1 ]
assert 'and its notes were not touched by the stale-note rule' notes_exist

no_note
run_start
assert 'a tentative boot with no staged note: rolled back, not promoted' [ "$ROLLED$PROMOTED" = 10 ]
assert 'and the log says why' wrote 'FAILED: no staged note on a tentative boot'

note_says 'VERSION=v2.57.0
GATE_NOTES=1'
no_gateway_note
run_start
assert 'a tentative boot that lost its gateway note: rolled back' [ "$ROLLED$PROMOTED" = 10 ]

# The migration through the whole decision tree: the image being replaced is
# stock, nothing was staged by our stager, and the board is healthy.
stock_was_running
no_note; no_gateway_note
run_start
assert 'a tentative boot from stock, no notes: promoted' [ "$ROLLED$PROMOTED" = 01 ]
assert 'and the log says it was accepted as another firmware, not failed' wrote 'is not this firmware'
assert 'and it was not logged as a failure' no_failure_logged

# ... and the same boot after a fork-to-fork staging that was cut.
fork_was_running
run_start
assert 'a tentative boot from this firmware, no notes: rolled back' [ "$ROLLED$PROMOTED" = 10 ]

# But a broken image from stock is rejected like any other: the leniency is
# about notes, never about health.
stock_was_running
stub_curl empty
run_start
assert 'a tentative boot from stock with broken /metrics: rolled back' [ "$ROLLED$PROMOTED" = 10 ]
stub_curl ok

# --- the marker: written by a normal boot, never by a tentative one --------
# What makes the cases above possible. A normal boot of this firmware records
# the image at "rootfs"; a tentative boot on rootfs_new must not, or a rejected
# image would vouch for itself.
echo 'quiet splash' >"$PROC_CMDLINE"; STUB_BLOCK=rootfs
stock_was_running; no_note; no_gateway_note; stub_printenv unset
run_start
assert 'a normal boot records the running image' grep -qx 'IMAGE=ubi0_1:23990272' "$RUNNING_IMAGE_NOTE"
assert 'and the version, for a human' grep -qx 'VERSION=v2.57.0' "$RUNNING_IMAGE_NOTE"
assert 'and says so in the log' wrote 'recorded the running image ubi0_1:23990272'
run_start
assert 'a second normal boot rewrites nothing and logs nothing' [ ! -s "$LOGFILE" ]

# The image at "rootfs" changes (a stock install, the SD card installer): the
# next normal boot of this firmware records the new one.
ubi_reset; ubi_vol rootfs 3 11111111
run_start
assert 'a changed image is recorded again' grep -qx 'IMAGE=ubi0_3:11111111' "$RUNNING_IMAGE_NOTE"

# A tentative boot, promoted or rejected, on rootfs_new: not recorded by start().
stock_was_running
echo 'quiet postupdate' >"$PROC_CMDLINE"; STUB_BLOCK=rootfs_new
no_note; no_gateway_note
printf 'IMAGE=ubi0_9:9\n' >"$RUNNING_IMAGE_NOTE"
run_start
assert 'a tentative boot does not touch the marker (the image has not earned it)' grep -qx 'IMAGE=ubi0_9:9' "$RUNNING_IMAGE_NOTE"

# ... until it is promoted. postupdate() is stubbed above, so its last step,
# the record, is exercised directly: after the rename the running volume is
# named rootfs, and an update staged before the next reboot must find it.
STUB_BLOCK=rootfs
ubi_reset; ubi_vol rootfs 2 24000000; ubi_vol rootfs_prev 1 23990272
: >"$LOGFILE"
record_running_image >/dev/null
assert 'a promotion records the image that is now rootfs' grep -qx 'IMAGE=ubi0_2:24000000' "$RUNNING_IMAGE_NOTE"

# No overlay, or a volume whose size cannot be read: nothing written, nothing fatal.
rm -f "$RUNNING_IMAGE_NOTE"; rm -f "$UBI_SYS/ubi0/ubi0_2/data_bytes"
record_running_image >/dev/null
assert 'an unreadable volume size records nothing' [ ! -e "$RUNNING_IMAGE_NOTE" ]
saved_marker=$RUNNING_IMAGE_NOTE
RUNNING_IMAGE_NOTE="$WORK/no-overlay/running-image"
record_running_image >/dev/null
assert 'no overlay: nothing written, and it returned' [ ! -e "$RUNNING_IMAGE_NOTE" ]
RUNNING_IMAGE_NOTE=$saved_marker
fork_was_running

# --- the stager ----------------------------------------------------------
stager() { GATEWAY_NOTE="$GATEWAY_NOTE" IP_BIN="$WORK/ip" PING_BIN="$PING_BIN" GATEWAY_SLEEP=0 sh "$STAGER" >/dev/null 2>&1; }

note_has() { grep -qx "$1" "$GATEWAY_NOTE" 2>/dev/null; }
note_absent() { [ ! -e "$GATEWAY_NOTE" ]; }
pings() { [ "$(wc -l <"$WORK/ping.calls" 2>/dev/null || echo 0)" -eq "$1" ]; }

stub_ip 'default via 10.0.0.1 dev br0 proto dhcp src 10.0.0.5 metric 10
'
stub_ping up
no_gateway_note
stager
assert 'stager records the gateway address' note_has 'GATEWAY=10.0.0.1'
assert 'stager records that it answered' note_has 'GATEWAY_PING=ok'
assert 'stager pinged once when the first answered' pings 1

# One ping is not a measurement (BMC-Firmware#126): a blip during staging used
# to record "none" right after a download through the same gateway worked, and
# the gate then skipped its network check for that image.
stub_ping late
no_gateway_note
stager
assert 'stager retries: a gateway that answers on the third try is ok' note_has 'GATEWAY_PING=ok'
assert 'stager stopped pinging once it answered' pings 3

stub_ping down
stager
assert 'stager records a silent gateway as none, not ok' note_has 'GATEWAY_PING=none'
assert 'stager tried five times before giving up' pings 5

# No route: still a note, saying so. A tentative boot that finds NO note after
# the staged note promised one is an interrupted staging; a board with no
# route is not.
stub_ping up
stager
assert 'a gateway that answers is on record before the route goes' note_has 'GATEWAY_PING=ok'
stub_ip ''
stager
assert 'stager records "no gateway" without a default route' note_has 'GATEWAY_PING=none'
assert 'and an empty gateway address' note_has 'GATEWAY='
assert 'and the stale "answered" note is gone, not left to be required' sh -c '! grep -q "GATEWAY_PING=ok" "$1"' _ "$GATEWAY_NOTE"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
