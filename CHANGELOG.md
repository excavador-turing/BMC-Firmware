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

### Fixed

- **Attaching a serial console could kill the board.** The kernel is built with
  `CONFIG_MAGIC_SYSRQ=y` and boots with `console=ttyS0`, so a BREAK on that line
  is a SysRq trigger and the next byte is the command. USB-serial adapters
  assert BREAK as a matter of course when a port is opened, closed, or has its
  line settings changed. Nothing set `kernel.sysrq`, so the full command set was
  live, including reboot, power off and SIGKILL-everything.

  A board was lost to this on 2026-09-09, within two minutes of an FTDI adapter
  being wired to the BMC UART while the board was otherwise healthy. The console
  was being added as a *recovery* tool, which makes this the worst possible
  place for the hazard to live.

  The mask is now `0x1a` in two places: `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE`, so
  it holds from the first instruction of the kernel, and `S00sysrq`, which
  re-applies it at runtime. That is 2 (console log level) + 8 (debugging dumps)
  + 16 (sync) -- so `w`, `m` and `t` still work on a hung board, while remount
  read-only, process signalling, reboot and power off are gone.


### Added

- A **Threads** panel on the dashboard, over `bmcd_process_threads` (bmcd
  2.20.0), sitting beside Memory in the BMC health row. The pairing is the
  point: a heap leak grows the resident set with the thread count flat, while a
  leaked task grows both. Neither series existed during the 2026-09-09 outage,
  which is why it could not be attributed.
- A **gate on the build** (`build.yml`). This file has said since it was
  written that "a two-hour Buildroot run for a file that never reaches the
  board is waste", and nothing enforced it -- every push to `hive` cost two
  hours whether or not it could change a byte of the image. A short job now
  decides, and the build waits on it.

  It fails open in every uncertain case: a tag, a dispatch, a pull request, a
  new branch, a force push, an unreadable diff. **Tags always build**, so a
  release can never be skipped by this whatever it decides. Verified against
  four representative file sets and a real commit pair.

### Not yet pinned

- bmcd **2.20.0** adds `bmcd_process_threads`, which the new panel reads. The
  pin still points at 2.19.0: there is no point cutting a firmware release
  while the board cannot be flashed (SQU-172). Bump it with the next release.

- A Grafana dashboard, `dashboards/turingpi-bmc.json`, published as a release
  asset and checksummed into `SHA256SUMS`. It covers every metric the daemon
  emits in five rows, including the two added after the 2026-09-09 outage: the
  daemon's own resident set beside the board's free memory, and the promotion
  gate's record, which until now existed only in `/mnt/overlay/postupdate.log`
  and so was readable only on a board that answers.
- `tests/dashboard.sh`, run by `checks.yml`. It guards one specific regression:
  a dashboard re-exported from a Grafana UI bakes in that instance's datasource
  uid and drops `__inputs`, which still parses, still imports for its author,
  and is silently useless to everyone else. Verified by breaking the file three
  ways and confirming each is caught with a reason.


## [v2.11.0] — 2026-09-09

Built but **not installed**: the board wedged before this could be flashed and
needs a physical power cycle first (SQU-172). This is the image to install when
it comes back.

### Changed

- bmcd **2.19.0**: the health gate's history as a metric
  (`bmcd_firmware_promotion_total`), the daemon's own resident set
  (`bmcd_process_resident_bytes`), a `refreshing` flag that can no longer stick
  through a panic, and a rollback slot whose version can finally be named.
- BMC-UI **3.10.1**: a red warning on v2.5 boards that flashing may not target
  the module you chose, a bounded poll on the firmware page, and Reset network
  made destructive with a confirmation that says what it costs.
- `tpi` **1.2.2**: `firmware install` works — it had never worked in any
  release — and `firmware list --refresh` waits for the daemon's re-poll.

### Added

- The gate records what a promoted image replaced, so a rollback can be named
  rather than reported as "version not readable".

## [v2.10.0] — 2026-09-09

### Changed

- bmcd **2.16.0**: every API operation has a path of its own —
  `GET /api/bmc/thermal`, `POST /api/bmc/hostname` — over the same dispatcher
  as the `?opt=&type=` form, which stays as it is; refusals on the new paths
  are RFC 9457 problem documents; and the daemon describes itself at
  `/api/bmc/openapi.json` (OpenAPI 3.1, response bodies not yet typed).
- `tpi` **1.2.2**: `firmware install` works — it had never worked in any
  release — and `firmware list --refresh` waits for the daemon's re-poll
  instead of printing the previous list.

## [v2.9.2] — 2026-09-09

### Changed

- BMC-UI **3.9.2**: each firmware source lists its newest three versions,
  always, with the rest behind "show N more". The previous rule showed only
  versions at or above the running one, which left an empty card the moment
  the board ran something no source had published yet.

## [v2.9.1] — 2026-09-09

### Changed

- `tpi` **1.2.1** and BMC-UI **3.9.1**. The CLI in v2.9.0 was the one whose
  every fork command failed against a real board — the first release of the
  tool ever run against one found five bugs, all fixed here. The interface's
  USB selector no longer prints its label through its value, and every
  candidate from a GitHub source has a link to its release notes beside
  Install.

## [v2.9.0] — 2026-09-09

### Changed

- bmcd **2.15.1**, `tpi` **1.2.0**, BMC-UI **3.9.0**. Between them this release
  carries: a firmware catalogue that answers from cache and refreshes behind
  itself instead of blocking the page for sixteen seconds; park mode, so an
  uploaded image lands on the SD card and installing stays a separate choice;
  the hostname and the time servers as settings; configuration export and
  import before board B; the thermal zone's trip points, so the fan's step has
  a reason attached; a seven-tab interface reorganised around what a person is
  doing; and a command line that reaches all of it.

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

[Unreleased]: https://github.com/excavador-turing/BMC-Firmware/compare/v2.11.0...hive
[v2.11.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.11.0
[v2.10.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.10.0
[v2.9.2]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.9.2
[v2.9.1]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.9.1
[v2.9.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.9.0
[v2.8.1]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.8.1
[v2.8.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.8.0
[v2.7.0]: https://github.com/excavador-turing/BMC-Firmware/releases/tag/v2.7.0
