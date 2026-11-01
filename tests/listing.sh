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
#   file    -- whatever $STUB_FILE holds (the real-shaped fixtures below)
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
	file)
		cat "$STUB_FILE"
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
	STUB_MODE="$mode" STUB_FILE="${STUB_FILE:-}" PATH="$bin:$PATH" OS_RELEASE="$osrelease" \
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

# --- the shape GitHub really returns ----------------------------------------
#
# Cases 1-3 feed the parser compact JSON, which is not what the API sends:
# it sends ~690 KB of pretty-printed text for 44 releases, one key per line,
# with nested `author`/`assets`/`uploader` objects and braces inside strings.
# Parsing that took 170 s on a board (measured 2026-11-01) and lost every
# `prerelease` flag, and no test noticed because none had the real shape.
#
# tests/fixtures/github-releases.json is a response fetched from
# api.github.com/repos/excavador-turing/BMC-Firmware/releases on 2026-11-01
# and trimmed (nine releases, two assets each, bodies cut to 300 characters),
# keeping the layout. One body was extended by hand with a JSON snippet, to
# put `},{` and a quoted "tag_name" inside a string.
fixture=tests/fixtures/github-releases.json
want="v2.46.1 v2.46.0 v2.45.0 v2.44.0 v2.43.0 v2.42.0 v2.9.2 v2.9.1 v2.9.0"

# tags_of / pre_of read the one-line JSON `--list` prints.
tags_of() { grep -o '"tag":"[^"]*"' "$work/out" | sed 's/"tag":"\(.*\)"/\1/' | tr '\n' ' ' | sed 's/ $//'; }
pre_of()  { grep -o '"tag":"'"$1"'","prerelease":[a-z]*' "$work/out" | sed 's/.*://'; }

echo "4. the real, pretty-printed response"
STUB_FILE=$fixture
status=$(run file --list --repo excavador-turing/BMC-Firmware)
[ "$status" -eq 0 ] \
	&& ok "exits 0" \
	|| bad "exited $status: $(cat "$work/err")"
[ "$(tags_of)" = "$want" ] \
	&& ok "lists every tag, newest first, and no tag from inside a body" \
	|| bad "tags were: $(tags_of)"
[ "$(wc -l < "$work/out")" -eq 1 ] \
	&& ok "still one JSON line" \
	|| bad "not one line"
[ "$(pre_of v2.46.1)" = "false" ] \
	&& ok "a stable release is not a prerelease" \
	|| bad "v2.46.1 prerelease=$(pre_of v2.46.1)"
grep -q '"tag":"v2.46.1","prerelease":false,"newer":true,"current":false,"relation":"newer"' "$work/out" \
	&& ok "relation to the running v2.35.0 is still computed (newer and older)" \
	|| bad "relation lost: $(cat "$work/out")"

echo "5. prerelease and draft are read, wherever they sit"
# Flip the flags inside one release each, the way GitHub would write them.
sed '/"tag_name": "v2.44.0"/,/"prerelease"/ s/"prerelease": false/"prerelease": true/' \
	"$fixture" > "$work/pre.json"
sed '/"tag_name": "v2.43.0"/,/"draft"/ s/"draft": false/"draft": true/' \
	"$work/pre.json" > "$work/pre-draft.json"
grep -q '"prerelease": true' "$work/pre.json" \
	|| bad "test setup: the prerelease flip did not apply"
STUB_FILE=$work/pre-draft.json
run file --list --repo excavador-turing/BMC-Firmware > /dev/null
[ "$(pre_of v2.44.0)" = "true" ] \
	&& ok "a prerelease is reported as one" \
	|| bad "v2.44.0 prerelease=$(pre_of v2.44.0)"
[ "$(pre_of v2.45.0)" = "false" ] && [ "$(pre_of v2.42.0)" = "false" ] \
	&& ok "its neighbours are not" \
	|| bad "the flag leaked to a neighbour"
grep -q '"tag":"v2.43.0"' "$work/out" \
	&& bad "a draft was listed" \
	|| ok "a draft is skipped"
[ "$(tags_of | wc -w)" -eq 8 ] \
	&& ok "and nothing else was lost with it" \
	|| bad "tags were: $(tags_of)"

echo "6. the same response on one line"
# Pretty-printing only puts newlines BETWEEN tokens (a string's own newlines
# are escaped), so deleting them leaves valid JSON.
tr -d '\n' < "$work/pre-draft.json" > "$work/one-line.json"
STUB_FILE=$work/one-line.json
run file --list --repo excavador-turing/BMC-Firmware > /dev/null
[ "$(pre_of v2.44.0)" = "true" ] && [ "$(tags_of | wc -w)" -eq 8 ] \
	&& ok "same answer as the pretty-printed form" \
	|| bad "tags were: $(tags_of)"

echo "7. a listing grows linearly, not per line"
# 90 releases, ~9000 lines. The old parser forked five times per line and
# took seconds here; one pass takes a fraction of one.
{
	echo "["
	n=0
	while [ "$n" -lt 10 ]; do
		[ "$n" -eq 0 ] || echo ","
		sed '1d;$d' "$fixture"
		n=$((n + 1))
	done
	echo "]"
} > "$work/big.json"
STUB_FILE=$work/big.json
t0=$(date +%s)
run file --list --repo excavador-turing/BMC-Firmware > /dev/null
t1=$(date +%s)
[ "$(tags_of | wc -w)" -eq 90 ] \
	&& ok "all 90 releases" \
	|| bad "tags were: $(tags_of | wc -w)"
[ $((t1 - t0)) -le 2 ] \
	&& ok "in $((t1 - t0)) s" \
	|| bad "took $((t1 - t0)) s for 90 releases"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
