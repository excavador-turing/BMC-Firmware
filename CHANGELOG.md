# Changelog

Turing Pi 2 BMC firmware, as built by this fork. Upstream's own history is in
the git log; this file starts where the fork diverges.

Versions follow upstream's numbering and continue past it — upstream's last
release is v2.1.0 (2025-02-05). A release is cut whenever the **built image**
changes. Changes that touch only CI, tests or documentation get a commit and an
entry under Unreleased, but no tag: a two-hour Buildroot run for a file that
never reaches the board is waste.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Contract tests for the promotion gate** (`tests/gate.sh`). The gate decides
  whether a freshly booted image is kept or rejected, and nothing checked it: a
  change that promoted everything would have been found by a flash, or not at
  all. The harness sources `S99postupdate`, points its paths at scratch files,
  stubs `curl`, and asserts both the verdict and the reason for twelve cases —
  four of which must be **rejections**. It runs under `dash` and under
  `busybox ash`, the board's own shell.
- A `checks` workflow that runs those tests and `shellcheck` on every push, in
  under a minute, separately from the two-hour image build. It also **mutates
  the gate twice and requires the suite to catch both**: a suite that stays
  green when a rejection is removed is decorative.

### Changed

- **A release candidate no longer outranks its own release** (SQU-169).
  `is_newer` in `tpi-selfupdate` used GNU `sort -V` alone, which puts
  `v2.8.1-rc1` *after* `v2.8.1` — so a board on the finished release was
  offered its own candidate as an upgrade, and `--check` would have exited 10
  for ever. It now compares the numeric part first and only then the suffix,
  where carrying one loses to carrying none. `v2.2.0-unstable-hive.12` is
  likewise work towards v2.2.0 rather than after it.
- `tests/version.sh` covers that ordering — eighteen cases including the tenth
  minor release, which a lexical compare gets wrong — and CI mutates the
  function back to the old behaviour and requires the suite to notice.
- `tpi-selfupdate` can be sourced with `TPI_SELFUPDATE_LIB=1` to get its
  functions without running the update. That is what makes the above testable
  without a network or a board.
- `S99postupdate` takes the path to `curl` from `CURL_BIN` rather than a
  literal, so the harness can exercise the `-x` check and the argument handling
  instead of bypassing them.

## [v2.8.1] — 2026-09-09

### Added

- **`turingpi.local` resolves again** (SQU-162). Dropping avahi for rootfs
  headroom (SQU-110) also removed the board's mDNS advertisement, and nothing
  replaced it — so `tpi` with no `--host` has failed since v2.3.0, because its
  default host is literally `turingpi.local`, and upstream's documentation
  tells people to reach the board that way. Nobody noticed here because this
  estate always passes an address.

  `mdnsd` replaces avahi: BSD-3, about 40 KB, and no D-Bus, expat or libdaemon
  behind it — which is what made avahi expensive, not avahi itself. The board
  advertises its own hostname, so a default image is `turingpi.local` again and
  a renamed board is whatever it was renamed to.
- The web interface is advertised as `_https._tcp` on 443, so a Bonjour browser
  finds the board. Port 443 rather than the port-80 redirect: advertising the
  redirect costs a client two round trips to reach a page that was always going
  to be served over TLS.
- **The promotion gate checks that the image is the one that was staged, and
  that it serves metrics** (SQU-140). The two existing checks prove the image
  is *alive* — the daemon answers, the switch ports exist — and neither proves
  it is *correct*: a build whose `/metrics` was completely broken would have
  been promoted. `release_matches()` now also requires that `/etc/os-release`
  agrees with the version named in the staged note, and that `/metrics`
  answers with `bmcd_build_info`.

  Verified on hardware: a note tampered to `v0.0.1` rolled the board back to
  v2.8.0 in about 35 seconds with the disagreement in `postupdate.log` — the
  first rollback this firmware has ever performed — and the same image,
  installed untampered, promoted. Every compute module's uptime continued
  uninterrupted through both reboots.

  Two details the board taught this change. `/metrics` has **no loopback
  exception** — only `/api/bmc` does — so the gate asks the daemon for a token
  via `type=metrics_token`, which mints one if none exists; reading the overlay
  file instead would have rolled back every good image on a fresh board. And a
  staged note that names a file but no version now says so, rather than
  claiming there was no note at all.

### Changed

- bmcd **2.10.1** and `tpi` **1.1.1**. Between them: a parked image is ordered
  against the running version instead of showing as `unknown`, and
  `tpi firmware install` can actually install one — 1.1.0 posted it to an
  endpoint the daemon refuses for local sources, so the resolution succeeded
  and the install failed with a 400.

## [v2.8.0] — 2026-09-08

### Changed

- First release built entirely in `excavador-turing`. Firmware sources point at
  this fork; `tpi-selfupdate` follows.
- bmcd 2.10.0, `tpi` 1.1.0, BMC-UI 3.7.0.

## [v2.7.0] — 2026-09-08

### Added

- Re-cut of the fork's work under the new organisation, carrying the versions
  the board was already running so that no board-visible version goes
  backwards.

### Changed

- Kernel 6.12.109 LTS (upstream: 6.8, never a longterm release).
- Buildroot 2025.02.17 LTS (upstream: 2024.05.1, end of life).
- Health-gated A/B promotion: a new image boots tentatively and is kept only
  if the daemon answers and every compute module's switch port is present.
  Otherwise the board reboots onto the image it had.
- A firmware update no longer power-cycles the compute modules.
- The board temperature is exposed through `thermal_zone0`, and the kernel
  drives the fan from it instead of a fixed persisted speed.
- `SHA256SUMS` published per release and verified on download.

[Unreleased]: https://github.com/excavador-turing/BMC-Firmware/compare/v2.8.1...hive
[v2.8.1]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.8.1
[v2.8.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.8.0
[v2.7.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.7.0
