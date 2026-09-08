#!/bin/sh
#
# Contract tests for the release ordering in tpi-selfupdate.
#
# Two functions decide what the board is offered: is_versioned() says whether
# a tag can be ordered at all, and is_newer() says which of two is later.
# Between them they answer "is there an upgrade", which drives `--check`'s
# exit code, the catalogue's `relation` field, and the UI's upgrade banner.
#
# Both have been wrong in production. An unversioned build once sorted first
# and made every release look like an upgrade; `sort -V` alone puts a release
# candidate AFTER its own release, so a board on the finished version was
# offered the candidate for ever.
#
# The script is sourced in library mode, so nothing here touches the network,
# the flash, or a staged image.
#
# Run:  sh tests/version.sh
#
set -u

SCRIPT=${SCRIPT:-tp2bmc/board/tp2bmc/overlay/sbin/tpi-selfupdate}

if [ ! -f "$SCRIPT" ]; then
	echo "cannot find $SCRIPT -- run this from the repository root" >&2
	exit 2
fi

TPI_SELFUPDATE_LIB=1
export TPI_SELFUPDATE_LIB
# shellcheck disable=SC1090
. "./$SCRIPT"

PASS=0
FAIL=0

#
# newer CANDIDATE RUNNING   -- CANDIDATE must be offered as an upgrade
# older CANDIDATE RUNNING   -- it must not be
#
newer() {
	if is_newer "$1" "$2"; then
		printf 'PASS  %-24s is newer than %s\n' "$1" "$2"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-24s should be newer than %s\n' "$1" "$2"
		FAIL=$((FAIL + 1))
	fi
}

older() {
	if is_newer "$1" "$2"; then
		printf 'FAIL  %-24s should NOT be newer than %s\n' "$1" "$2"
		FAIL=$((FAIL + 1))
	else
		printf 'PASS  %-24s is not newer than %s\n' "$1" "$2"
		PASS=$((PASS + 1))
	fi
}

versioned() {
	if is_versioned "$1"; then
		printf 'PASS  %-24s is version-shaped\n' "$1"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-24s should be version-shaped\n' "$1"
		FAIL=$((FAIL + 1))
	fi
}

unversioned() {
	if is_versioned "$1"; then
		printf 'FAIL  %-24s should NOT be version-shaped\n' "$1"
		FAIL=$((FAIL + 1))
	else
		printf 'PASS  %-24s is not version-shaped\n' "$1"
		PASS=$((PASS + 1))
	fi
}

echo "release ordering -- $SCRIPT"
echo

# --- the ordinary case ---------------------------------------------------
newer v2.8.0 v2.7.0
older v2.7.0 v2.8.0
older v2.8.0 v2.8.0

# --- the tenth minor release ---------------------------------------------
# A lexical compare puts v2.9.0 above v2.10.0. This is why `sort -V` is here
# at all, and the case is kept so a "simplification" back to a string compare
# fails immediately rather than at the tenth release.
newer v2.10.0 v2.9.0
older v2.9.0 v2.10.0

# --- a release candidate -------------------------------------------------
# `sort -V` gets the first of these right and the second WRONG: it puts
# v2.8.1-rc1 after v2.8.1, so a board on the finished release is offered its
# own candidate as an upgrade and --check exits 10 for ever.
newer v2.8.1-rc1 v2.8.0
older v2.8.1-rc1 v2.8.1
newer v2.8.1 v2.8.1-rc1
newer v2.8.1-rc2 v2.8.1-rc1
older v2.8.1-rc1 v2.8.1-rc2

# --- the fork's own unstable tags ----------------------------------------
# Work towards v2.2.0, not after it.
older v2.2.0-unstable-hive.12 v2.2.0
newer v2.2.0-unstable-hive.12 v2.1.0
# hive.10 after hive.9, which a lexical sort reverses.
newer v2.2.0-unstable-hive.10 v2.2.0-unstable-hive.9

# --- what can be ordered at all ------------------------------------------
versioned v2.8.0
versioned v2.8.1-rc1
versioned 2.8.0
unversioned local
unversioned tp2-bmc-firmware-ota-local.tpu

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
