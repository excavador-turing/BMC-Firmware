#!/bin/sh
#
# The order osupdate does things in, and the lock it takes.
#
# An update has one commit point: `fw_setenv nextboot`. Everything the
# promotion gate reads (the staged-version note and the gateway note) has to be
# on disk, synced, BEFORE it. It used to be after, and a power cut or a reboot
# from another client in the window produced a tentative boot with no notes,
# which the gate then waved through (BMC-Firmware#126). And nothing serialised
# two stagers, which met in ubi_cleanup (#127).
#
# These cases run the real osupdate against stubs of every tool it calls
# (ubirmvol, ubimkvol, ubiupdatevol, ubirename, fw_setenv, fw_printenv, sync,
# the gateway recorder) and a scratch /sys/class/ubi. The stubs write one
# line each to a trace, in call order, and the arming stub also records what
# was on disk at that instant. No board, no flash, no root.
#
# Run:  sh tests/osupdate.sh
#
set -u

SCRIPT=${SCRIPT:-tp2bmc/board/tp2bmc/overlay/sbin/osupdate}
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
bin="$work/bin"
ubi="$work/ubi"
blk="$work/block"
overlay="$work/overlay"
trace="$work/trace"
mkdir -p "$bin" "$ubi" "$blk" "$overlay"

# The volumes of a board that has taken an update before: rootfs (mounted,
# so it has a ubiblock device), rootfs_prev and a leftover rootfs_new.
fake_ubi() {
	rm -rf "$ubi" "$blk"
	mkdir -p "$ubi/ubi0/ubi0_1" "$ubi/ubi0/ubi0_2" "$ubi/ubi0/ubi0_3" "$blk/ubiblock0_1"
	printf 'rootfs\n' > "$ubi/ubi0/ubi0_1/name"
	printf 'rootfs_prev\n' > "$ubi/ubi0/ubi0_2/name"
	printf 'rootfs_new\n' > "$ubi/ubi0/ubi0_3/name"
}

# Every tool records itself. `fw_setenv nextboot VALUE` also records which
# notes existed at that instant and whether a sync had run since the last
# note was written -- the two facts the commit point depends on.
for tool in ubirmvol ubimkvol ubirename; do
	cat > "$bin/$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >> "$trace"
STUB
done
cat > "$bin/ubiupdatevol" <<'STUB'
#!/bin/sh
echo "ubiupdatevol $*" >> "$STUB_TRACE"
[ -z "${STUB_UBIUPDATEVOL_FAIL:-}" ] || {
	echo 'ubiupdatevol: error!: cannot write 94208 bytes to volume "/dev/ubi0_3"' >&2
	exit 1
}
STUB
cat > "$bin/sync" <<'STUB'
#!/bin/sh
echo "sync" >> "$STUB_TRACE"
: > "$STUB_SYNCED"
STUB
cat > "$bin/fw_printenv" <<'STUB'
#!/bin/sh
# Whatever is in $STUB_NEXTBOOT_FILE, or "not defined".
if [ -s "$STUB_NEXTBOOT_FILE" ]; then
	cat "$STUB_NEXTBOOT_FILE"
	exit 0
fi
echo '## Error: "nextboot" not defined' >&2
exit 1
STUB
cat > "$bin/fw_setenv" <<'STUB'
#!/bin/sh
if [ $# -eq 1 ]; then
	echo "fw_setenv $1 (unset)" >> "$STUB_TRACE"
	: > "$STUB_NEXTBOOT_FILE"
	exit 0
fi
[ -z "${STUB_FW_SETENV_FAIL:-}" ] || { echo "Cannot write the environment" >&2; exit 1; }
staged=no; gateway=no; synced=no
[ -f "$STAGED_NOTE" ] && staged=yes
[ -f "$GATEWAY_NOTE" ] && gateway=yes
[ -f "$STUB_SYNCED" ] && synced=yes
echo "fw_setenv $1 ARM staged_note=$staged gateway_note=$gateway synced=$synced" >> "$STUB_TRACE"
printf '%s\n' "$2" > "$STUB_NEXTBOOT_FILE"
STUB
# The gateway recorder: writes the note, as the real one does, unless told not
# to. It also removes the sync marker: the note it writes is not durable until
# the NEXT sync, which is what the arming stub checks.
cat > "$bin/gateway-recorder" <<'STUB'
#!/bin/sh
echo "stage-gateway-note" >> "$STUB_TRACE"
rm -f "$STUB_SYNCED"
case "${STUB_GATEWAY:-ok}" in
	ok) printf 'GATEWAY=10.0.0.1\nGATEWAY_PING=ok\n' > "$GATEWAY_NOTE" ;;
	fail) exit 1 ;;
	cut) kill -9 "$PPID" ;;
esac
STUB
chmod +x "$bin"/*

printf 'not really a firmware image\n' > "$work/image"
printf 'VERSION=v2.57.0\nSHA256=abc\nSOURCE=tpi-selfupdate\nREPLACES=v2.55.0\n' > "$work/note-in"

# run [ARGS...] -- the exit status on stdout; stdout and stderr in $work/out.
# `sh -eu` because the script's own `#!/bin/sh -eu` is not applied when a shell
# is named on the command line, and the script relies on both.
run() {
	: > "$trace"
	rm -f "$work/synced"
	STUB_TRACE="$trace" STUB_SYNCED="$work/synced" STUB_NEXTBOOT_FILE="$work/nextboot" \
	PATH="$bin:$PATH" UBI_SYS="$ubi" BLOCK_SYS="$blk" \
	STAGED_NOTE="$overlay/staged-firmware" GATEWAY_NOTE="$overlay/staged-gateway" \
	GATEWAY_NOTE_BIN="$bin/gateway-recorder" STAGE_LOCK="$work/stage.lock" SYNC_BIN="$bin/sync" \
	STUB_UBIUPDATEVOL_FAIL="${STUB_UBIUPDATEVOL_FAIL:-}" \
	STUB_FW_SETENV_FAIL="${STUB_FW_SETENV_FAIL:-}" STUB_GATEWAY="${STUB_GATEWAY:-ok}" \
		sh -eu "$SCRIPT" "$@" > "$work/out" 2>&1
	echo $?
}

reset() {
	fake_ubi
	rm -f "$overlay"/* "$work/nextboot" "$work/stage.lock"
	unset STUB_UBIUPDATEVOL_FAIL STUB_FW_SETENV_FAIL STUB_GATEWAY STAGE_LOCK_HELD
}

# line_of PATTERN -- the line number of the first trace line matching it.
line_of() { grep -n "$1" "$trace" | head -1 | cut -d: -f1; }
armed() { [ -s "$work/nextboot" ]; }

echo "1. a clean staging: notes first, synced, then nextboot"
reset
status=$(run "$work/image" "$work/note-in")
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status: $(cat "$work/out")"
armed && ok "nextboot is armed at the end" || bad "nextboot was never armed"
grep -q 'ARM staged_note=yes gateway_note=yes synced=yes' "$trace" \
	&& ok "at the moment nextboot was armed, both notes were on disk and a sync had followed" \
	|| bad "arming state: $(grep ARM "$trace")"
a=$(line_of 'ubiupdatevol'); b=$(line_of 'stage-gateway-note'); c=$(line_of '^sync'); d=$(line_of 'ARM')
{ [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]; } \
	&& ok "order: write the volume, gateway note, sync, arm nextboot LAST" \
	|| bad "order is wrong: $(tr '\n' ';' < "$trace")"
[ "$(wc -l < "$trace" | tr -d ' ')" -eq "$(line_of 'ARM')" ] \
	&& ok "arming nextboot is the last thing it does" \
	|| bad "something ran after the arming: $(tr '\n' ';' < "$trace")"
grep -qx 'VERSION=v2.57.0' "$overlay/staged-firmware" \
	&& ok "the stager's note was installed" || bad "no VERSION in the staged note"
grep -qx 'GATE_NOTES=1' "$overlay/staged-firmware" \
	&& ok "and carries the mark that the gateway note came first" \
	|| bad "no GATE_NOTES=1 in the staged note"
grep -qx 'GATEWAY_PING=ok' "$overlay/staged-gateway" \
	&& ok "the gateway note is there" || bad "no gateway note"
grep -q '^ubirmvol /dev/ubi0 -N rootfs_prev' "$trace" && grep -q '^ubirmvol /dev/ubi0 -N rootfs_new' "$trace" \
	&& ok "the old spare volumes were removed" || bad "volumes: $(grep ubirmvol "$trace" | tr '\n' ';')"
grep -q 'ubirmvol /dev/ubi0 -N rootfs$' "$trace" \
	&& bad "the running volume was removed" || ok "the running volume was not"

echo "2. no note handed over: osupdate writes a minimal one, so the gate still has one"
reset
status=$(run "$work/image")
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status: $(cat "$work/out")"
grep -qx 'SOURCE=osupdate' "$overlay/staged-firmware" && grep -qx 'FILE=image' "$overlay/staged-firmware" \
	&& ok "a minimal staged note exists" || bad "note: $(cat "$overlay/staged-firmware" 2>&1)"

echo "3. the write fails: nothing is armed and no note is left behind"
reset
STUB_UBIUPDATEVOL_FAIL=1; export STUB_UBIUPDATEVOL_FAIL
status=$(run "$work/image" "$work/note-in")
[ "$status" -ne 0 ] && ok "exits non-zero" || bad "exit status $status"
! armed && ok "nextboot was not armed" || bad "nextboot was armed after a failed write"
[ ! -e "$overlay/staged-firmware" ] && [ ! -e "$overlay/staged-gateway" ] \
	&& ok "no note describes an image that was not staged" \
	|| bad "left behind: $(ls "$overlay" | tr '\n' ' ')"

echo "4. arming itself fails: the notes go too"
reset
STUB_FW_SETENV_FAIL=1; export STUB_FW_SETENV_FAIL
status=$(run "$work/image" "$work/note-in")
[ "$status" -ne 0 ] && ok "exits non-zero" || bad "exit status $status"
[ ! -e "$overlay/staged-firmware" ] && [ ! -e "$overlay/staged-gateway" ] \
	&& ok "no notes without nextboot" || bad "left behind: $(ls "$overlay" | tr '\n' ' ')"

echo "5. power cut while the gateway is being recorded (the window of #126)"
reset
STUB_GATEWAY="cut"; export STUB_GATEWAY
run "$work/image" "$work/note-in" > /dev/null
! armed && ok "nextboot is NOT armed: a cut before the notes are done boots the old image" \
	|| bad "nextboot was armed although the notes were never finished"
[ ! -e "$overlay/staged-firmware" ] \
	&& ok "and the staged note was never written, so nothing claims a staged image" \
	|| bad "a staged note exists"

echo "6. the gateway recorder fails: not fatal, and no promise is made"
reset
STUB_GATEWAY="fail"; export STUB_GATEWAY
status=$(run "$work/image" "$work/note-in")
[ "$status" -eq 0 ] && armed && ok "the update still goes ahead" || bad "status $status, armed=$(armed && echo yes || echo no)"
grep -q 'GATE_NOTES' "$overlay/staged-firmware" \
	&& bad "the note promises a gateway note that does not exist" \
	|| ok "the staged note does not claim a gateway note"

echo "7. an earlier staging is still armed: it is disarmed before its volume goes"
reset
printf 'bootmode=postupdate; distro_bootpart=rootfs_new; run boot_do_scan\n' > "$work/nextboot"
printf 'VERSION=v2.50.0\n' > "$overlay/staged-firmware"
status=$(run "$work/image" "$work/note-in")
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status: $(cat "$work/out")"
a=$(line_of 'fw_setenv nextboot (unset)'); b=$(line_of 'ubirmvol')
{ [ -n "$a" ] && [ "$a" -lt "$b" ]; } \
	&& ok "nextboot was cleared before any volume was removed" \
	|| bad "order: $(tr '\n' ';' < "$trace")"
grep -qx 'VERSION=v2.57.0' "$overlay/staged-firmware" \
	&& ok "and the old note was replaced" || bad "stale note survived"

echo "8. another stager holds the lock: refused, nothing touched"
reset
( exec 9> "$work/stage.lock"; flock -n 9 && sleep 3 ) &
holder=$!
sleep 1
status=$(run "$work/image" "$work/note-in")
[ "$status" -eq 75 ] && ok "exits 75" || bad "exit status $status"
grep -q 'an update is being staged' "$work/out" \
	&& ok "says an update is being staged" || bad "message: $(cat "$work/out")"
grep -qi 'power' "$work/out" \
	&& bad "gives power advice for a busy lock" || ok "gives no power-cycle advice"
[ ! -s "$trace" ] && ok "no volume was touched" || bad "ran: $(tr '\n' ';' < "$trace")"
! armed && ok "nothing was armed" || bad "armed"

echo "9. the caller holds the lock and says so: osupdate does not wait on itself"
reset
STAGE_LOCK_HELD=1; export STAGE_LOCK_HELD
status=$(run "$work/image" "$work/note-in")
unset STAGE_LOCK_HELD
[ "$status" -eq 0 ] && ok "exits 0 while another process holds the file lock" || bad "exit status $status: $(cat "$work/out")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "10. the lock is released when it is done: a second run goes through"
reset
status=$(run "$work/image" "$work/note-in")
status2=$(run "$work/image" "$work/note-in")
{ [ "$status" -eq 0 ] && [ "$status2" -eq 0 ]; } && ok "two runs in a row both succeed" || bad "statuses $status $status2"

echo "11. a board with no overlay can still update"
reset
rm -rf "$overlay"
status=$(run "$work/image" "$work/note-in")
mkdir -p "$overlay"
[ "$status" -eq 0 ] && armed && ok "armed, with nowhere to put a note" || bad "status $status"

echo "12. no argument is a usage error, and touches nothing"
reset
status=$(run)
[ "$status" -eq 2 ] && [ ! -s "$trace" ] && ok "exit 2, nothing ran" || bad "status $status"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
