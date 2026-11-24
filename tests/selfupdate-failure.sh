#!/bin/sh
#
# A failed write must leave the board as it found it, and say so.
#
# An outside tester's update failed on the last partial LEB:
#
#   ubiupdatevol: error!: cannot write 94208 bytes to volume "/dev/ubi0_3"
#   error 110 (Connection timed out)
#
# After a write error other than EIO UBI switches the whole device read-only
# until the next boot, so a retry is useless and `tpi reboot` then failed with
# EIO too. osupdate stops before `fw_setenv nextboot`, so the board still boots
# the old image -- but the script used to leave the ~39 MB download in
# /mnt/overlay (which has very little room) and print nothing about any of it.
#
# These cases stub curl, df, fw_printenv and osupdate: no network, no board, no
# flash. The staging directories are plain directories listed in a fake
# /proc/mounts.
#
# Run:  sh tests/selfupdate-failure.sh
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
sd="$work/sdcard"
overlay="$work/overlay"
mkdir -p "$bin" "$sd" "$overlay"

osrelease="$work/os-release"
printf 'VERSION="v2.35.0"\n' > "$osrelease"

target=v2.36.0
image="tp2-bmc-firmware-ota-$target.tpu"
printf 'not really a firmware image\n' > "$work/payload"
sum=$(sha256sum "$work/payload" | cut -d' ' -f1)

# curl: SHA256SUMS goes to stdout; the image is written to the -o file, or
# fails after writing half of it when $STUB_CURL_FAIL is set.
cat > "$bin/curl" <<'STUB'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		--max-time|--retry) shift 2 ;;
		-*) shift ;;
		*) url=$1; shift ;;
	esac
done
case "$url" in
	*/SHA256SUMS) printf '%s  %s\n' "$STUB_SUM" "$STUB_IMAGE" ;;
	*)
		if [ -n "${STUB_CURL_FAIL:-}" ]; then
			head -c 10 "$STUB_PAYLOAD" > "$out"
			echo "curl: (18) transfer closed with outstanding read data" >&2
			exit 18
		fi
		cat "$STUB_PAYLOAD" > "$out"
		;;
esac
STUB

# df: every directory has room.
cat > "$bin/df" <<'STUB'
#!/bin/sh
eval "dir=\${$#}"
echo "Filesystem 1K-blocks Used Available Use% Mounted"
echo "stub 900000 0 900000 0% $dir"
STUB

# fw_printenv: nothing is staged, unless $STUB_NEXTBOOT says what is.
cat > "$bin/fw_printenv" <<'STUB'
#!/bin/sh
[ -z "${STUB_NEXTBOOT:-}" ] || echo "$STUB_NEXTBOOT"
exit 0
STUB

# osupdate: records that it ran and where the image was, then does what
# $STUB_OSUPDATE says. The real one installs the note it is handed ($2) as the
# staged-version note, before it arms nextboot; this one does the same on
# success, and records what it was handed and whether it was told the staging
# lock is held.
cat > "$bin/osupdate" <<'STUB'
#!/bin/sh
echo "$1" > "$STUB_SEEN"
[ -f "$1" ] || exit 99
echo "note_arg=${2:-} lock_held=${STAGE_LOCK_HELD:-}" > "$STUB_SEEN.args"
[ -z "${2:-}" ] || cp "$2" "$STUB_SEEN.note"
case "${STUB_OSUPDATE:-ok}" in
	ok) [ -z "${2:-}" ] || cp "$2" "$STAGED_NOTE"; exit 0 ;;
	busy)
		echo 'ubirmvol: error!: cannot remove volume "rootfs_new"' >&2
		echo 'error 16 (Device or resource busy)' >&2
		exit 1
		;;
	locked) echo 'osupdate: an update is being staged; try again when it has finished' >&2; exit 75 ;;
	fail)
		echo 'ubiupdatevol: error!: cannot write 94208 bytes to volume "/dev/ubi0_3"' >&2
		echo 'error 110 (Connection timed out)' >&2
		exit 1
		;;
	exit2) exit 2 ;;
	slow) : > "$STUB_STARTED"; sleep 3; exit 0 ;;
esac
STUB
chmod +x "$bin/curl" "$bin/df" "$bin/fw_printenv" "$bin/osupdate"

# mounts: $1.. are the directories that count as mounts.
set_mounts() {
	: > "$work/mounts"
	for d in "$@"; do
		printf 'stub %s ext4 rw 0 0\n' "$d" >> "$work/mounts"
	done
}

# run ARGS... -- stdout and stderr kept apart; prints the exit status.
run() {
	rm -f "$work/out" "$work/err" "$work/seen" "$work/seen.args" "$work/seen.note" "$work/note"
	STUB_SUM="$sum" STUB_IMAGE="$image" STUB_PAYLOAD="$work/payload" \
	STUB_SEEN="$work/seen" STUB_STARTED="$work/started" \
	PATH="$bin:$PATH" OS_RELEASE="$osrelease" \
	OSUPDATE_BIN="$bin/osupdate" PROC_MOUNTS="$work/mounts" \
	STAGING_DIRS="$sd $overlay" STAGED_NOTE="$work/note" \
	STAGE_LOCK="$work/stage.lock" \
		sh "$SCRIPT" --tag "$target" "$@" > "$work/out" 2> "$work/err"
	echo $?
}

# Anything the script did not create, which must survive every case.
sentinels() {
	for d in "$sd" "$overlay"; do
		printf 'precious\n' > "$d/user-file"
		printf 'precious\n' > "$d/$image"
	done
}
only_sentinels() {
	# $1 is the directory; true when nothing but the sentinels is in it.
	[ "$(ls -A "$1" | sort | tr '\n' ' ')" = "$image user-file " ]
}
reset() {
	rm -rf "$sd" "$overlay"
	mkdir -p "$sd" "$overlay"
	sentinels
	unset STUB_OSUPDATE STUB_CURL_FAIL STUB_NEXTBOOT STAGE_LOCK_HELD
}

echo "1. the write fails (error 110 from ubiupdatevol)"
reset
set_mounts "$sd"
STUB_OSUPDATE=fail; export STUB_OSUPDATE
status=$(run)
[ "$status" -eq 1 ] \
	&& ok "exits 1" \
	|| bad "exit status $status"
[ -s "$work/seen" ] \
	&& ok "osupdate was reached with a staged image" \
	|| bad "osupdate never ran: $(cat "$work/err")"
only_sentinels "$sd" \
	&& ok "the staged image is gone and nothing else was touched" \
	|| bad "left in the staging dir: $(ls -A "$sd" | tr '\n' ' ')"
grep -q 'untouched' "$work/err" \
	&& ok "says the running firmware is untouched" \
	|| bad "no word on the running firmware: $(cat "$work/err")"
grep -q 'power-cycle' "$work/err" && grep -q 'read-only' "$work/err" \
	&& ok "says UBI may be read-only and to power-cycle" \
	|| bad "no power-cycle advice: $(cat "$work/err")"
grep -q 'SD card' "$work/err" \
	&& ok "points at flashing from the SD card" \
	|| bad "no mention of the SD card: $(cat "$work/err")"
[ ! -e "$work/note" ] \
	&& ok "no staged-version note was written" \
	|| bad "a note claims an image that was not staged"
grep -q 'staged .* for the next boot' "$work/err" \
	&& bad "claims to have staged it" \
	|| ok "does not claim to have staged anything"

echo "2. the same, with --keep: a failed write still deletes the image"
reset
set_mounts "$sd"
STUB_OSUPDATE=fail; export STUB_OSUPDATE
status=$(run --keep)
[ "$status" -eq 1 ] && only_sentinels "$sd" \
	&& ok "exits 1 and leaves nothing behind" \
	|| bad "status $status; left: $(ls -A "$sd" | tr '\n' ' ')"

echo "3. osupdate exits 2 (which means 'up to date' for this script)"
reset
set_mounts "$sd"
STUB_OSUPDATE=exit2; export STUB_OSUPDATE
status=$(run)
[ "$status" -eq 1 ] \
	&& ok "still a failure, exit 1" \
	|| bad "exit status $status"

echo "4. the download breaks off half way"
reset
set_mounts "$sd"
STUB_CURL_FAIL=1; export STUB_CURL_FAIL
status=$(run)
[ "$status" -eq 1 ] \
	&& ok "exits 1" \
	|| bad "exit status $status"
only_sentinels "$sd" \
	&& ok "the partial download is removed" \
	|| bad "left in the staging dir: $(ls -A "$sd" | tr '\n' ' ')"

echo "5. a checksum mismatch"
reset
set_mounts "$sd"
sum_saved=$sum
sum=0000000000000000000000000000000000000000000000000000000000000000
status=$(run)
sum=$sum_saved
[ "$status" -eq 1 ] && only_sentinels "$sd" \
	&& ok "exits 1 and removes the download" \
	|| bad "status $status; left: $(ls -A "$sd" | tr '\n' ' ')"

echo "6. a write that works"
reset
set_mounts "$sd"
status=$(run)
[ "$status" -eq 0 ] \
	&& ok "exits 0" \
	|| bad "exit status $status: $(cat "$work/err")"
only_sentinels "$sd" \
	&& ok "the staged image is removed once written" \
	|| bad "left in the staging dir: $(ls -A "$sd" | tr '\n' ' ')"
grep -q "^VERSION=$target\$" "$work/note" 2>/dev/null \
	&& ok "the staged-version note is written" \
	|| bad "no note"

echo "7. a write that works, with --keep"
reset
set_mounts "$sd"
status=$(run --keep)
[ "$status" -eq 0 ] \
	&& ok "exits 0" \
	|| bad "exit status $status: $(cat "$work/err")"
cmp -s "$sd/$image" "$work/payload" \
	&& ok "the image is kept under its real name" \
	|| bad "kept image missing or wrong"
[ "$(ls -A "$sd" | wc -l)" -eq 2 ] \
	&& ok "and no temporary file is left next to it" \
	|| bad "left in the staging dir: $(ls -A "$sd" | tr '\n' ' ')"

echo "8. interrupted during the write"
reset
set_mounts "$sd"
STUB_OSUPDATE=slow; export STUB_OSUPDATE
rm -f "$work/started" "$work/note"
STUB_SUM="$sum" STUB_IMAGE="$image" STUB_PAYLOAD="$work/payload" \
STUB_SEEN="$work/seen" STUB_STARTED="$work/started" \
PATH="$bin:$PATH" OS_RELEASE="$osrelease" \
OSUPDATE_BIN="$bin/osupdate" PROC_MOUNTS="$work/mounts" \
STAGING_DIRS="$sd $overlay" STAGED_NOTE="$work/note" \
STAGE_LOCK="$work/stage.lock" \
	sh "$SCRIPT" --tag "$target" > "$work/out" 2> "$work/err" &
pid=$!
n=0
while [ ! -e "$work/started" ] && [ "$n" -lt 100 ]; do
	sleep 0.1 2>/dev/null || sleep 1
	n=$((n + 1))
done
kill -TERM "$pid" 2>/dev/null
wait "$pid"
status=$?
[ "$status" -ne 0 ] \
	&& ok "exits non-zero ($status)" \
	|| bad "exited 0 after SIGTERM"
only_sentinels "$sd" \
	&& ok "the staged image is removed" \
	|| bad "left in the staging dir: $(ls -A "$sd" | tr '\n' ' ')"
[ ! -e "$work/note" ] \
	&& ok "no note for an image that was not written" \
	|| bad "a note was written"
unset STUB_OSUPDATE

echo "9. SD card present: preferred, no fallback message"
reset
set_mounts "$sd" "$overlay"
status=$(run --keep)
[ -f "$sd/$image" ] && cmp -s "$sd/$image" "$work/payload" && [ "$(cat "$overlay/$image")" = "precious" ] \
	&& ok "staged on the card, the overlay untouched" \
	|| bad "wrong staging directory"
grep -q "staging in $sd\$" "$work/err" && ! grep -q 'not usable' "$work/err" \
	&& ok "says so without a fallback warning" \
	|| bad "$(cat "$work/err")"

echo "10. no SD card mounted: falls back to the overlay and says so"
reset
set_mounts "$overlay"
status=$(run --keep)
cmp -s "$overlay/$image" "$work/payload" && [ "$(cat "$sd/$image")" = "precious" ] \
	&& ok "staged on the overlay, the empty card directory untouched" \
	|| bad "wrong staging directory"
grep -q "staging in $overlay: $sd is not usable" "$work/err" \
	&& ok "says why it is not on the card" \
	|| bad "$(cat "$work/err")"

echo "11. SD card mounted but read-only: falls back"
reset
set_mounts "$sd" "$overlay"
if [ "$(id -u)" -eq 0 ]; then
	echo "  skip running as root (a directory mode does not stop root)"
else
	chmod a-w "$sd"
	status=$(run --keep)
	chmod u+w "$sd"
	cmp -s "$overlay/$image" "$work/payload" \
		&& ok "staged on the overlay" \
		|| bad "wrong staging directory: $(cat "$work/err")"
	grep -q "$sd is not usable" "$work/err" \
		&& ok "says so" \
		|| bad "$(cat "$work/err")"
fi

echo "12. the note is written BEFORE osupdate runs, and handed to it"
reset
set_mounts "$sd"
status=$(run)
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status: $(cat "$work/err")"
grep -q '^note_arg=.*\.note ' "$work/seen.args" \
	&& ok "osupdate was given a note file as its second argument" \
	|| bad "args: $(cat "$work/seen.args" 2>&1)"
grep -q "^VERSION=$target\$" "$work/seen.note" \
	&& grep -q '^REPLACES=v2.35.0$' "$work/seen.note" \
	&& grep -q '^SOURCE=tpi-selfupdate$' "$work/seen.note" \
	&& ok "and that note names the version, what it replaces and who staged it" \
	|| bad "note: $(cat "$work/seen.note" 2>&1)"
only_sentinels "$sd" \
	&& ok "neither the note file nor the stderr file is left behind" \
	|| bad "left in the staging dir: $(ls -A "$sd" | tr '\n' ' ')"

echo "13. a failed write leaves no note file and installs no note"
reset
set_mounts "$sd"
STUB_OSUPDATE=fail; export STUB_OSUPDATE
status=$(run)
[ ! -e "$work/note" ] && only_sentinels "$sd" \
	&& ok "no installed note, nothing left in the staging dir" \
	|| bad "status $status; left: $(ls -A "$sd" | tr '\n' ' ')"

echo "14. the lock is held by another stager: refused before anything is downloaded"
reset
set_mounts "$sd"
( exec 9> "$work/stage.lock"; flock -n 9 && sleep 4 ) &
holder=$!
sleep 1
status=$(run)
[ "$status" -eq 1 ] && ok "exits 1" || bad "exit status $status"
grep -q 'an update is being staged' "$work/err" \
	&& ok "says an update is being staged" || bad "$(cat "$work/err")"
grep -qi 'power' "$work/err" \
	&& bad "advises a power cycle for a busy lock: $(cat "$work/err")" \
	|| ok "and gives no power-cycle advice"
[ ! -e "$work/seen" ] && only_sentinels "$sd" \
	&& ok "osupdate never ran and the staging directory was not touched" \
	|| bad "something ran: $(ls -A "$sd" | tr '\n' ' ')"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "15. the caller holds the lock (bmcd does): this run does not wait on it"
reset
set_mounts "$sd"
( exec 9> "$work/stage.lock"; flock -n 9 && sleep 4 ) &
holder=$!
sleep 1
STAGE_LOCK_HELD=1; export STAGE_LOCK_HELD
status=$(run)
unset STAGE_LOCK_HELD
[ "$status" -eq 0 ] && ok "exits 0" || bad "exit status $status: $(cat "$work/err")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "16. a run that took the lock tells osupdate so"
reset
set_mounts "$sd"
status=$(run)
grep -q 'lock_held=1$' "$work/seen.args" \
	&& ok "osupdate saw STAGE_LOCK_HELD=1 and will not take the lock again" \
	|| bad "args: $(cat "$work/seen.args" 2>&1)"

echo "17. an update is already armed: refused, and the advice is to unstage"
reset
set_mounts "$sd"
STUB_NEXTBOOT='bootmode=postupdate; distro_bootpart=rootfs_new'; export STUB_NEXTBOOT
status=$(run)
unset STUB_NEXTBOOT
[ "$status" -eq 1 ] && ok "exits 1" || bad "exit status $status"
grep -q "tpi firmware unstage" "$work/err" \
	&& ok "points at tpi firmware unstage" || bad "$(cat "$work/err")"
grep -q "fw_setenv" "$work/err" \
	&& bad "still advises fw_setenv by hand" || ok "and no longer at fw_setenv by hand"
[ ! -e "$work/seen" ] && ok "osupdate never ran" || bad "osupdate ran over an armed update"

echo "18. EBUSY from the volume tools: no power-cycle advice (BMC-Firmware#127)"
reset
set_mounts "$sd"
STUB_OSUPDATE=busy; export STUB_OSUPDATE
status=$(run)
[ "$status" -eq 1 ] && ok "exits 1" || bad "exit status $status"
grep -q 'remove power' "$work/err" \
	&& bad "advises a power cycle for EBUSY: $(cat "$work/err")" \
	|| ok "no power-cycle advice"
grep -qi 'busy' "$work/err" && grep -q 'do NOT power-cycle' "$work/err" \
	&& ok "says the volume is busy and not to power-cycle for it" \
	|| bad "$(cat "$work/err")"
only_sentinels "$sd" && ok "the download is still deleted" || bad "left: $(ls -A "$sd" | tr '\n' ' ')"

echo "19. osupdate itself finds the lock taken (exit 75)"
reset
set_mounts "$sd"
STUB_OSUPDATE=locked; export STUB_OSUPDATE
status=$(run)
[ "$status" -eq 1 ] && ok "exits 1" || bad "exit status $status"
grep -q 'remove power' "$work/err" \
	&& bad "advises a power cycle for a busy lock" || ok "no power-cycle advice"
grep -q 'an update is being staged' "$work/err" \
	&& ok "says an update is being staged" || bad "$(cat "$work/err")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
