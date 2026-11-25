#!/bin/sh
#
# Taking back a staged update: /sbin/osunstage.
#
# `tpi firmware unstage`, the web interface's "Cancel staged update" and
# bmcd's `opt=set&type=firmware_unstage` all end here (BMC-Firmware#124). The
# order matters the way it does for staging, mirrored: nextboot goes FIRST,
# because it is the commit point, and the notes after it; a cut in between
# leaves notes without nextboot, which S99postupdate discards at the next boot.
#
# Stubs of fw_printenv and fw_setenv; scratch overlay, SD card and /tmp.
#
# Run:  sh tests/osunstage.sh
#
set -u

SCRIPT=${SCRIPT:-tp2bmc/board/tp2bmc/overlay/sbin/osunstage}
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
bin="$work/bin"
overlay="$work/overlay"
sd="$work/sdcard"
tmp="$work/tmp"
trace="$work/trace"
mkdir -p "$bin" "$overlay" "$sd/firmware" "$tmp"

cat > "$bin/fw_printenv" <<'STUB'
#!/bin/sh
if [ -s "$STUB_NEXTBOOT_FILE" ]; then
	cat "$STUB_NEXTBOOT_FILE"
	exit 0
fi
echo '## Error: "nextboot" not defined' >&2
exit 1
STUB
cat > "$bin/fw_setenv" <<'STUB'
#!/bin/sh
[ -z "${STUB_FW_SETENV_FAIL:-}" ] || { echo "Cannot write the environment" >&2; exit 1; }
notes=no
[ -f "$STAGED_NOTE" ] && notes=yes
echo "fw_setenv $* notes_still_there=$notes" >> "$STUB_TRACE"
: > "$STUB_NEXTBOOT_FILE"
STUB
chmod +x "$bin"/*

stage_everything() {
	printf 'bootmode=postupdate; distro_bootpart=rootfs_new; run boot_do_scan\n' > "$work/nextboot"
	printf 'VERSION=v2.57.0\nSOURCE=tpi-selfupdate\n' > "$overlay/staged-firmware"
	printf 'GATEWAY=10.0.0.1\nGATEWAY_PING=ok\n' > "$overlay/staged-gateway"
	mkdir -p "$tmp/os_upgrade" "$overlay/os_upgrade"
	printf 'x' > "$tmp/os_upgrade/tp2-bmc-firmware-ota-v2.57.0.tpu"
	printf 'x' > "$overlay/.tp2-bmc-firmware-ota-v2.57.0.tpu.1234"
	printf 'x' > "$overlay/.tp2-bmc-firmware-ota-v2.57.0.tpu.1234.note"
	printf 'x' > "$sd/.tp2-bmc-firmware-ota-v2.57.0.tpu.99.err"
	printf 'a parked image\n' > "$sd/firmware/tp2-bmc-firmware-ota-v2.60.0.tpu"
	printf 'a kept image\n' > "$overlay/tp2-bmc-firmware-ota-v2.56.0.tpu"
	printf 'quiet\n' > "$work/cmdline"
}
reset() {
	rm -rf "$overlay" "$sd" "$tmp" "$work/nextboot" "$work/stage.lock"
	mkdir -p "$overlay" "$sd/firmware" "$tmp"
	: > "$trace"
	unset STUB_FW_SETENV_FAIL STAGE_LOCK_HELD
}

run() {
	STUB_TRACE="$trace" STUB_NEXTBOOT_FILE="$work/nextboot" PATH="$bin:$PATH" \
	STAGED_NOTE="$overlay/staged-firmware" GATEWAY_NOTE="$overlay/staged-gateway" \
	STAGE_LOCK="$work/stage.lock" PROC_CMDLINE="$work/cmdline" \
	STAGING_DIRS="$sd $overlay $tmp" \
	STUB_FW_SETENV_FAIL="${STUB_FW_SETENV_FAIL:-}" \
		sh -eu "$SCRIPT" > "$work/out" 2>&1
	echo $?
}
armed() { [ -s "$work/nextboot" ]; }
no_notes() { [ ! -e "$overlay/staged-firmware" ] && [ ! -e "$overlay/staged-gateway" ]; }

echo "1. an armed update, fully staged"
reset; stage_everything
status=$(run)
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status: $(cat "$work/out")"
! armed && ok "nextboot is cleared" || bad "still armed"
no_notes && ok "both notes are gone" || bad "left: $(ls "$overlay" | tr '\n' ' ')"
grep -q 'notes_still_there=yes' "$trace" \
	&& ok "nextboot was cleared BEFORE the notes were removed" \
	|| bad "order: $(cat "$trace")"
[ ! -e "$tmp/os_upgrade" ] && [ ! -e "$overlay/os_upgrade" ] \
	&& ok "the upload worker's staging directories are removed" \
	|| bad "os_upgrade left"
leftovers=$(find "$overlay" "$sd" -maxdepth 1 -name '.tp2-bmc-firmware-ota-*')
[ -z "$leftovers" ] \
	&& ok "a stager's temporary files are removed" || bad "a stager's temporary files are left"
[ -f "$sd/firmware/tp2-bmc-firmware-ota-v2.60.0.tpu" ] \
	&& ok "a parked image on the card is untouched" || bad "the parked image is gone"
[ -f "$overlay/tp2-bmc-firmware-ota-v2.56.0.tpu" ] \
	&& ok "an image kept with --keep is untouched" || bad "a kept image is gone"
grep -q 'unstaged v2.57.0' "$work/out" && ok "says what it unstaged" || bad "$(cat "$work/out")"
grep -c fw_setenv "$trace" | grep -qx 1 && ok "fw_setenv ran once, with nextboot alone" \
	|| bad "trace: $(cat "$trace")"
grep -q 'fw_setenv nextboot notes' "$trace" && ok "and it only unset the variable" || bad "trace: $(cat "$trace")"

echo "2. nothing staged: says so, writes nothing"
reset
status=$(run)
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status"
grep -q 'nothing is staged' "$work/out" && ok "says nothing is staged" || bad "$(cat "$work/out")"
[ ! -s "$trace" ] && ok "fw_setenv never ran: no flash write for nothing" || bad "trace: $(cat "$trace")"

echo "3. notes with no nextboot (a cut between the two): cleaned, and no flash write"
reset; stage_everything
: > "$work/nextboot"
status=$(run)
[ "$status" -eq 0 ] && no_notes && ok "the notes are removed" || bad "status $status"
[ ! -s "$trace" ] && ok "nextboot was not touched" || bad "trace: $(cat "$trace")"

echo "4. twice in a row"
reset; stage_everything
run >/dev/null
status=$(run)
[ "$status" -eq 0 ] && ok "the second run is a no-op that succeeds" || bad "status $status"

echo "5. a stager holds the lock: refused, nothing touched"
reset; stage_everything
( exec 9> "$work/stage.lock"; flock -n 9 && sleep 3 ) &
holder=$!
sleep 1
status=$(run)
[ "$status" -eq 75 ] && ok "exits 75" || bad "exit status $status"
grep -q 'an update is being staged' "$work/out" && ok "says an update is being staged" || bad "$(cat "$work/out")"
armed && [ -f "$overlay/staged-firmware" ] && [ -d "$tmp/os_upgrade" ] \
	&& ok "nextboot, notes and the stager's files are all as they were" \
	|| bad "something was touched"

echo "6. the caller holds the lock and says so (bmcd does)"
STAGE_LOCK_HELD=1; export STAGE_LOCK_HELD
status=$(run)
unset STAGE_LOCK_HELD
[ "$status" -eq 0 ] && ! armed && ok "goes ahead" || bad "exit status $status: $(cat "$work/out")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "7. a tentative boot is being judged: refused"
reset; stage_everything
: > "$work/nextboot"
printf 'console=ttyS0 postupdate\n' > "$work/cmdline"
status=$(run)
[ "$status" -eq 4 ] && ok "exits 4" || bad "exit status $status"
[ -f "$overlay/staged-firmware" ] \
	&& ok "the staged note stays, so the gate is not pulled out from under" \
	|| bad "the note was removed under the gate"
grep -q 'being checked' "$work/out" && ok "says the new firmware is being checked" || bad "$(cat "$work/out")"

echo "8. a normal boot whose command line says postupdate but has no staged note"
reset
printf 'console=ttyS0 postupdate\n' > "$work/cmdline"
status=$(run)
[ "$status" -eq 0 ] && ok "is not a tentative boot being judged" || bad "exit status $status"

echo "9. the environment cannot be written: still armed, notes kept, exit 1"
reset; stage_everything
STUB_FW_SETENV_FAIL=1; export STUB_FW_SETENV_FAIL
status=$(run)
unset STUB_FW_SETENV_FAIL
[ "$status" -ne 0 ] && ok "exits non-zero" || bad "exit status $status"
armed && [ -f "$overlay/staged-firmware" ] \
	&& ok "nothing was half done: still armed, notes still there" \
	|| bad "half done"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
