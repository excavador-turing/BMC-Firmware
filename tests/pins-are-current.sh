#!/usr/bin/env bash
# A firmware release ships the LATEST bmcd, BMC-UI and tpi. Standing rule,
# owner's, 2026-09-11.
#
# The reason it is a check and not a habit: every one of these pins is a
# 64-character hash in a file nobody reads, and the cost of forgetting is
# invisible. Firmware v2.22.0 shipped BMC-UI v3.21.0 while v3.22.0 had been
# released for hours — nothing was wrong, nothing was red, and the board
# simply ran an older interface than the one the site was advertising.
#
# On a PR this REPORTS. On a tag it FAILS: a release is the moment the rule
# has to hold, and failing every PR because somebody released a daemon an hour
# ago would make the check something people learn to ignore.
#
# Needs only the public API; all four repositories are public.
set -uo pipefail

ORG=excavador-turing
here=$(cd "$(dirname "$0")/.." && pwd)
stale=0

api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else
        curl -fsSL "$1"
    fi
}

# The tip of a repository's default branch.
head_of() {
    api "https://api.github.com/repos/${ORG}/$1/commits/hive" \
        | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1
}

# The newest published, non-draft release tag.
latest_release() {
    api "https://api.github.com/repos/${ORG}/$1/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

report() {
    local name="$1" pinned="$2" latest="$3"
    if [ -z "$latest" ]; then
        echo "  ?? $name: could not ask GitHub what the latest is; not treating that as current"
        stale=$((stale + 1))
        return
    fi
    if [ "$pinned" = "$latest" ]; then
        printf '  ok %-8s %s\n' "$name" "$pinned"
    else
        printf '  ST %-8s pinned %s, latest %s\n' "$name" "$pinned" "$latest"
        stale=$((stale + 1))
    fi
}

# bmcd and tpi are pinned by commit against the default branch.
bmcd_pinned=$(sed -n 's/^BMCD_VERSION = \([0-9a-f]*\).*/\1/p' "$here/tp2bmc/package/bmcd/bmcd.mk")
tpi_pinned=$(sed -n 's/^TPI_VERSION:= *\([0-9a-f]*\).*/\1/p' "$here/tp2bmc/package/tpi/tpi.mk")
# BMC-UI is fetched as a release asset, so its pin is a tag.
ui_pinned=$(sed -n 's/^BMC_UI_VERSION = \(.*\)/\1/p' "$here/tp2bmc/package/bmc-ui/bmc-ui.mk")

echo "What this firmware pins:"
report bmcd   "$bmcd_pinned" "$(head_of bmcd)"
report tpi    "$tpi_pinned"  "$(head_of tpi)"
report BMC-UI "$ui_pinned"   "$(latest_release BMC-UI)"

if [ "$stale" -eq 0 ]; then
    echo "All three are current."
    exit 0
fi

echo
echo "$stale pin(s) are not the latest."

# GITHUB_REF is refs/tags/v* only on a release build.
case "${GITHUB_REF:-}" in
    refs/tags/v*)
        echo "This is a RELEASE. A release ships the latest of all three; bump the"
        echo "pins, recompute the hashes, and tag again."
        exit 1
        ;;
    *)
        echo "Not a release, so this is a note rather than a failure. It becomes one"
        echo "the moment this tree is tagged."
        exit 0
        ;;
esac
