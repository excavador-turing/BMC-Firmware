#!/usr/bin/env python3
"""Compose a release body from CHANGELOG.md, for the tag being built.

Every release used to carry the same fixed paragraph. Two releases four days
and fourteen entries apart published byte-identical notes, so the one place a
reader looks first -- the release itself -- said nothing about what changed,
while CHANGELOG.md in this repository had the whole story.

This takes the standing part (what the artefacts are, how to verify them) and
puts the tag's own section from CHANGELOG.md in the middle of it.

    scripts/release-notes.py v2.32.0 > notes.md

A standard release with no section in CHANGELOG.md is an error: a release that
changes the image and says nothing is the thing this exists to prevent. A
prerelease (a `-` in the tag, e.g. v2.2.0-unstable-hive.3) is cut from a branch
mid-flight and is allowed to have no entry yet.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The guide this points at moved with the site (turing.excavador.xyz has been
# dead since SQU-189 and every release published since has carried a 502).
DOCS = "https://turingpi.xyz"

PREAMBLE = """Turing Pi 2 BMC firmware, built from the `hive` branch.

**Not a Turing Pi release.** Upstream is dormant: last release
v2.1.0 (2025-02-05), last commit 2025-08-28, and the lead
maintainer stated on 2026-06-16 that he has moved on.

Includes the unmerged versioning fix (upstream PR #242), so
`/etc/os-release` reports the actual firmware version instead of
Buildroot's."""

TRAILER = f"""`.tpu` is the OTA package, `.img` the recovery SD image.
Verify with `sha256sum -c SHA256SUMS`.

`turingpi-bmc-dashboard.json` is a Grafana dashboard over the
metrics this build's daemon emits. Import it and pick your
Prometheus-compatible datasource; see
{DOCS}/guides/monitor-it/

The full history, including every release before this one, is at
{DOCS}/changelog/firmware/."""


def section(changelog: str, tag: str) -> str | None:
    """The body under `## [<tag>] — <date>`, up to the next `## `.

    Matched on the tag with and without its leading v, because the heading
    style has used both and a release must not fail over a letter.
    """
    bare = tag.lstrip("v")
    pattern = re.compile(
        r"^##\s*\[v?" + re.escape(bare) + r"\][^\n]*\n(.*?)(?=^##\s|\Z)",
        re.M | re.S,
    )
    found = pattern.search(changelog)
    if not found:
        return None
    body = found.group(1).strip()
    return body or None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: release-notes.py <tag>", file=sys.stderr)
        return 2
    tag = sys.argv[1]
    changelog = (ROOT / "CHANGELOG.md").read_text()
    body = section(changelog, tag)

    if body is None:
        if "-" not in tag:
            print(
                f"{tag} has no section in CHANGELOG.md. A release that changes "
                f"the image and says nothing about it is not publishable; add "
                f"`## [{tag}]` with what changed, and tag again.",
                file=sys.stderr,
            )
            return 1
        body = (
            "A prerelease cut from `hive` in flight. Its changes are under "
            f"[Unreleased]({DOCS}/changelog/firmware/) until a standard "
            "release carries them."
        )

    print(PREAMBLE)
    print()
    print(f"## What changed in {tag}")
    print()
    print(body)
    print()
    print("---")
    print()
    print(TRAILER)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
