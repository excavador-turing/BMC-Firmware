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

## [v2.24.0] — 2026-09-11

Everything current: the daemon, the interface and the CLI.

### Fixed

- **bmcd v2.32.0 → v2.34.0.** Two releases.

  **v2.33.0 — a node's USB bus number is not part of its identity, and pinning
  it refused every flash** (SQU-199). The port check that stops a flash of
  node 2 writing node 1 compared the whole path, bus included, against a bus
  hardcoded to 1. This board pairs an OHCI and an EHCI controller as
  **companions for the same physical ports**, so which bus a device lands on is
  decided by its *speed*: the same hub port is `1-1.2` for a full-speed device
  and `2-1.2` for a high-speed one. A Rockchip in maskrom is high-speed, so the
  daemon refused every RK1 it was asked to flash or expose as mass storage,
  with `node 2 requested on 1-1.2; found Rockusb on 2-1.2 instead`, about
  modules that were entirely healthy. **Nothing on this board could be flashed
  through the daemon until this release.**

  **v2.34.0 — the daemon can say what is on the microSD card** (SQU-198). Name,
  size, modified time, and whether each entry could be written to a node.
  `tpi flash --local` already reads images off that card; there was simply no
  way to see what was there, so an operator had to know the path and type it.
  A non-candidate is listed with its reason rather than hidden. Every path is
  confined to the card by one function with its own tests, catching `../..` and
  a symlink off the card with the same rule.

- **BMC-UI v3.21.0 → v3.23.0.** v3.22.0 stopped the daemon's messages being
  escaped twice — i18next escapes interpolated values and React escapes again,
  so a path arrived as `&#x2F;` in the page.

  v3.23.0 is the fleet gaining every control the board interface has, built
  from the **same components** rather than copies. That reaches this package
  too, because those components are the board's own bundle: toasts were capped
  at one and carried no board name, "don't ask again" for node power was a
  single setting shared by every board, and logout walked out of the
  application under a sub-path. All three are fixed here as well. Export and
  Import configuration is now **Backup and restore**.

- **tpi → 79ff091: the rename does not move your metrics history.** Renaming a
  board was described as carrying its metrics with it. The series carry no
  board name at all, so nothing moves, and the CLI stops claiming otherwise.

## [v2.23.0] — 2026-09-11

TLS, made usable rather than merely present.

### Changed

- **bmcd v2.30.0 → v2.32.0: the daemon offers TLS 1.3, with 1.2 as the
  fallback** (SQU-136). Its acceptor was built from Mozilla's version 4
  intermediate profile, which pins the maximum protocol version to TLS 1.2.
  The board's OpenSSL is 3.5.7 and was capable of 1.3 the whole time.

  Not housekeeping. Under TLS 1.2 a client's `supported_groups` extension
  constrains the curve of the **server's** certificate as well as the key
  exchange, so a client whose list stops at P-256 — Envoy's default — cannot
  use a P-384 certificate at all. Every certificate in the estate these boards
  run in is P-384, so the gateway in front of them failed every handshake and
  both boards showed as unreachable behind a login page that worked perfectly.

- **The self-signed certificate is one a client can actually trust, and it
  renews itself.** The script that issues it, when nobody has installed a real
  certificate, had four problems, each now fixed:

  - It set **no subjectAltName**. Every browser since 2017 matches on the SAN
    and ignores the common name, so that certificate could not be accepted by
    any of them. A self-signed certificate nobody can choose to trust is
    decoration. It now names the board's hostname, its `.local` name and every
    global address it holds.
  - It was valid for **30 days** — openssl's default, never passed — and only
    ever regenerated when a file was missing. A board left running served an
    expired certificate for as long as it stayed up; one here did for over a
    year (SQU-115). It now issues for 825 days and reissues 30 days before
    expiry, so neither a long uptime nor a month powered off produces an
    expired certificate.
  - It generated **RSA 4096** on a board with about 87 MB of usable RAM. Now
    EC P-384, the estate's standing key type: stronger per bit, faster, smaller.
  - Its pair check ran `openssl rsa -noout -modulus`, which **fails on any key
    that is not RSA** — and the failure branch deletes both files and
    regenerates. An operator installing an EC or Ed25519 certificate could have
    it destroyed at the next boot. It now compares public keys, which works for
    every key type, and **refuses to touch any certificate it did not issue**:
    a certificate from a real CA is left exactly where it is, expired or not,
    with a warning rather than a replacement.

  Fifteen assertions cover this in CI, including the two that matter most: a
  certificate this script did not issue comes out byte for byte unchanged.

### Added

- **`/metrics` says when the serving certificate expires** —
  `bmcd_tls_certificate_expiry_timestamp_seconds` — and which key it is built
  on, `bmcd_tls_certificate_info{key="ecdsa-p384"}`. A number a scrape can
  alert on is the difference between noticing an expiry and a calendar
  reminder somebody stops reading. A date the daemon cannot parse reports no
  series at all rather than a zero, which would read as 1970 and fire every
  rule written against it.

### Confirmed

- **Every key an operator might install is served**, over TLS 1.3 and 1.2
  alike: RSA, EC P-256, P-384 and P-521, and Ed25519. Already true, now a test
  that performs a real handshake per key type against the real acceptor.

## [v2.22.0] — 2026-09-11

### Added

- **bmcd v2.29.0 → v2.30.0: a proxy holding a certificate from a trusted CA
  can name the human it authenticated** (SQU-136). `tls.client_ca` turns it
  on and is absent by default, so a board that never gets one behaves exactly
  as before. `tls.identity_header` says which header carries the name. A name
  without a certificate is nobody, and that rule has a test.

  This is what makes a fleet interface possible without giving anything a
  password to every board.

## [v2.21.0] — 2026-09-10

### Changed

- **BMC-UI v3.19.0 → v3.21.0**, two interface releases in one pin. v3.20.0
  put the Nodes page on a two-by-two grid — four full-width rows scrolled on
  a 1080-pixel screen with a third of the width empty beside each — and added
  the demo mode that answers from captured fixtures, which is what
  turingpi.xyz serves as its live demo. v3.21.0 tightened that grid until it
  also fits the demo's frame: measured at 868 pixels in the 1664 by 879 frame
  the site gives it.
- **The Grafana dashboard names the board on every series.** With two boards
  reporting, a panel that did not carry the instance label was drawing both
  as one line.


## [v2.20.0] — 2026-09-10

### Added

- **bmcd v2.28.0 → v2.29.0: `bmcd_firmware_last_promotion_timestamp_seconds`**
  (SQU-141). The counter beside it says how often the gate reached a verdict;
  this says when the last one was, which is what an alert on "no promotion
  since" needs. Absent rather than wrong when the board's clock cannot be
  trusted, and only UTC is accepted.

### Removed

- **BMC-UI v3.18.0 → v3.19.0: the red maskrom warning on the flash page**
  (SQU-157, with SQU-105). It said the daemon writes to whichever module is in
  maskrom first, whatever the picker says. That was true and is not any more.

  Proven on the board on 2026-09-10 before the warning came down: with **two**
  modules in maskrom at once, flashing node 2 left node 4 answering `talosctl`
  with the cluster's certificate authority while node 2 rejected it as unknown.
  A node that was overwritten cannot present the cluster CA; one that was not
  cannot fail to. The write landed where it was aimed, and node 2 was
  reprovisioned back into the cluster afterwards.

  A warning that is no longer true is worse than no warning: it teaches people
  to ignore the red ones.

## [v2.19.0] — 2026-09-10

### Changed

- **`tpi` v1.5.1 → v1.6.0: the check that caused all of this is gone.**

  Three releases in a row carried attempts to make `firmware install` resolve
  a version correctly against the board's cached listing. The listing lags a
  release by up to half an hour, so `firmware check` would print
  `install it with: tpi firmware install <v>` and the next command would
  reject it. v2.17.0's attempt was inert; v2.18.0's worked by waiting up to
  three minutes.

  Both were the wrong shape. The resolution existed because of a comment
  claiming the board would otherwise fail "in the middle of a download".
  Measured: the daemon answers **400 in 0.48 s** with
  `tpi-selfupdate: cannot fetch SHA256SUMS for v9.9.9`, before any download,
  staging nothing. There was nothing to protect against.

  So the listing now informs the confirmation line and cannot refuse, and the
  board — which is what downloads the image — decides. On a version that
  exists nowhere: 140 s and a possibly-wrong refusal before, 1 s and the
  board's own message now.

### Fixed

- **`tpi firmware list --refresh` could confirm that a release did not
  exist.** It waited 60 s for a poll, then gave up and printed the previous
  listing with nothing said, indistinguishable from a current one. Polls
  measured on this board took 74 s, 78 s and 140 s. Now four minutes, it says
  when it gives up, and `list` prints how old the listing is on every run —
  the daemon had always sent that, and the client discarded it.

## [v2.18.0] — 2026-09-09

### Fixed

- **`tpi` v1.5.0 → v1.5.1: the fix v2.17.0 shipped did not work.** `firmware
  install` still refused the command `firmware check` had just printed.

  v1.5.0 asked the board to re-poll its firmware sources and resolved against
  the answer — but `firmware_available&refresh=1` does not fetch. The daemon
  *spawns* the poll and returns the cached list immediately with `refreshing`
  set, so the second resolution ran against the same stale list as the first.
  Confirmed on the board: a forced request came back in one second carrying
  the same `checked_at` it had before the call.

  v1.5.1 waits for the poll to land before re-resolving, keyed on
  `checked_at`, which advances exactly once a poll completes. Bounded at 180 s,
  and a refusal that hits the bound says the poll did not finish rather than
  claiming no source has the version.

  Proved on the board before this release rather than after, with a version
  that exists nowhere so nothing could install either way:

  | build | elapsed | `checked_at` |
  |---|---|---|
  | 1.5.0 | 1 s | unchanged |
  | 1.5.1 | 58 s | 20:50:57 → 20:52:11 |

## [v2.17.0] — 2026-09-09

> **The `tpi` change below is inert.** It describes behaviour v1.5.0 did not
> have; v2.18.0 carries the version that does. Kept as written, because a
> release note that quietly becomes true later teaches nobody anything.



### Changed

- **`tpi` v1.4.0 → v1.5.0.** `firmware install` no longer refuses the command
  `firmware check` just printed.

  The two read different caches with independent timing: `check` asks the
  board's update checker, which reaches GitHub, while `install` resolved the
  requested version against the firmware catalogue, whose entries are fresh
  for half an hour. Reproduced on a board twenty-seven seconds after v2.16.0
  published — `check` said `install it with: tpi firmware install v2.16.0` and
  exited 10; the next command said `no source offers v2.16.0` and exited 1.

  `install` now re-resolves against a forced poll before believing no source
  has the version. The successful path pays nothing. The refusal itself stays:
  posting an unresolved version would fail in the middle of a download rather
  than before it starts.

## [v2.16.0] — 2026-09-09

### Changed

- **bmcd v2.27.0 → v2.28.0.** The ten handlers that assembled their answer
  with `json!` now serialise named types, so every read operation in the
  OpenAPI document describes what it answers with and none is left as "not
  described here". The shapes are reconstructions of what the daemon already
  sent, odd corners preserved and explained: power, USB and SD card answer a
  one-element array because that is upstream's shape; node power reports
  strings because an unreadable rail is `Unknown` and a boolean could not say
  so; the SD card's used-bytes field is `use` on the wire because `use` is
  what upstream sent and a Rust keyword.

  **Naming a cooling device that does not exist now answers 400, not 500.**
  A client branches on status, and 500 is the retryable one — so the old
  answer asked callers to retry something that could never change.

- **BMC-UI v3.17.0 → v3.18.0.** Twenty-three hand-written response interfaces
  become aliases onto types generated from the `openapi.json` bmcd publishes,
  and CI regenerates and diffs, so a hand edit or a pin moved without
  regenerating fails there rather than on a board. Nothing changes on screen.

  Two things this shook out. The generated types are stricter than the
  hand-written ones — schemars cannot tell a field always sent as `null` from
  one omitted when empty — so a reading is now recognised by a type guard
  rather than by a runtime check the compiler could not see. And BMC-UI's
  quality workflow had been `pull_request` only, in a fork that never opens
  one, so its lint, build and tests had never run in CI at all.

### Added

- **`docs/architecture.md`** — where the daemon, the interface and the
  listeners live, the board measurements the arrangement rests on, and what
  was declined along the way. Linked from the README.

### Fixed

- **CI's shell install no longer fails on a third-party apt repository it does
  not use.** A hash mismatch in the runner image's Google Chrome repository
  failed the promotion-gate job on a documentation-only change. The step now
  drops the runner's third-party `.list` files before updating.

## [v2.15.0] — 2026-09-09

### Changed

- **`/metrics` is served on port 9110, plain HTTP, with no credential**
  (SQU-178). It used to sit on `:443` beside the API and the web interface,
  behind TLS and a token of its own.

  The token existed for one reason: so that a credential in a scrape config
  could not also reach `/api/bmc` and power four compute modules off. On a
  listener that serves nothing but `/metrics` there is nothing else to reach,
  so the property survives and the mechanism is a port instead of a secret.
  The TLS was always scraped with verification disabled, because this board's
  certificate is expired and carries no SAN, so it bought nothing and cost a
  handshake per scrape on a Cortex-A7.

  **A scrape config pointed at `:443` will stop working.** Point it at 9110,
  drop the basic auth and drop the TLS block.

- **The promotion gate no longer depends on the `/api/bmc` loopback bypass.**
  It used to reach through it to mint itself a metrics token before it could
  check the endpoint; it now makes one plain request. The on-board `tpi` is
  the only remaining user of that bypass.

  `tests/gate.sh` shrank with it — the stub's token behaviour and the three
  cases exercising token retrieval are gone, replaced by one case for an
  endpoint that answers with the wrong body. Ten cases, all passing, and
  proven to fail by accepting any body at all.

- **bmcd v2.23.0 → v2.27.0**, **`tpi` v1.3.0 → v1.4.0**, **BMC-UI v3.15.0 →
  v3.17.0**. Beyond the metrics change: the OpenAPI document now describes
  what its operations answer with and is checked against what the daemon
  sends, `bmcd --openapi` prints it without a board, and the interface folded
  its standing explanations behind (i) popovers linking to the docs site.

### Removed

- **`/mnt/overlay/metrics-token`.** Nothing writes or reads it. An existing
  file is harmless and is simply ignored; the daemon will not recreate one.

## [v2.14.0] — 2026-09-09

### Changed

- **bmcd v2.19.0 → v2.23.0**, four releases:

    - **A fan can be held at a step** (SQU-170). `opt=set&type=cooling` takes
      `mode=manual` to pause the zone's governor and `mode=auto` to hand the
      fan back. Until now a written step was returned to the governor's own
      choice within a poll, which is what made the interface's slider a
      control that lied. A held fan is taken back above the zone's hottest
      `active` trip, because this board declares no `critical` trip and
      nothing else would intervene.

    - **A flash targets the module that was asked for** (SQU-105). All four
      modules sit behind one hub on a v2.5 board, and the daemon used to take
      whichever answered first — a flash of node 2 could write node 1 and
      report success. The node-to-port mapping is read from this board's own
      device tree rather than assumed.

    - **An audit line per mutating call** (SQU-108), naming the action, node,
      caller, address and outcome, and naming the loopback bypass explicitly
      when there was no credential at all. Sent to the system log as well as
      the rotating file, because `/tmp` and `/var/log` are both tmpfs here.

    - **`bmcd_process_threads`**, the companion to the resident-set metric.

- **`tpi` v1.2.2 → v1.3.0**: `cooling set --hold` and `--auto`, and a Governor
  column that says `-` rather than `running` on a daemon that does not report
  it.

- **BMC-UI v3.14.0 → v3.15.0**: the fan slider now sits behind an explicit
  Override switch, offered only where the daemon reports it can actually hold
  a step.

### Added

- **`/etc/default/syslogd`**, carrying the remote-logging knob documented and
  deliberately unset (SQU-108). `syslogd -R <host>:<port>` sends this board's
  kernel and daemon logs somewhere that survives a reboot; `/var/log` is a
  tmpfs and the overlay is the wrong answer, on a NAND with five free
  eraseblocks and a workload guaranteed to grow. A default pointing at a host
  nobody configured would make every boot wait on a DNS lookup.

## [v2.13.0] — 2026-09-09

### Changed

- BMC-UI **v3.10.1 → v3.14.0**, four releases of interface work:

  - The console replays the module's scrollback when you open it, instead of
    showing a blank terminal however long the module has been running, and
    gains a **Redraw** button.
  - The reboot dialogs stop claiming the compute modules lose power. They do
    not, and this fork's not cutting them is one of the things it exists for.
    Both live places said otherwise, in all six languages.
  - Rebooting from Settings now says when a firmware is staged, so a reboot for
    an unrelated reason no longer silently applies an update.
  - An upload no longer offers a reboot that would do nothing. It parks the
    image on the SD card, and the message says so.
  - **Install OS** is red, like every other consequential action, and the
    shared confirmation dialog commits in red rather than in the colour of
    Save.
  - The firmware sources editor no longer breaks at 390 px.

### Fixed

- **mDNS was eating the board** (SQU-175). This is the cause of both outages on
  2026-09-09, and it was ours.

  `mdnsd` binds every interface it can see. On this board that means the DSA
  switch ports — `node1`..`node4`, `ge0`, `dsa` — which share one MAC and one
  link-local address, because they are ports of a single switch rather than
  separate hosts. mdnsd announced on each, saw its own announcement arrive on
  the others, and called that a name conflict. Every conflict triggers a config
  reload, and mdnsd 0.12 leaks on reload.

  Measured on the board: **825 reloads in twelve seconds**, and the process
  growing **956 kB a minute** on a machine with 118 MB of RAM and no swap. That
  is ninety minutes from boot to a board that answers ping and nothing else.
  The same storm wrote those 825 log lines into `/var/log`, which is on the
  58 MB tmpfs, so it was consuming memory from both ends.

  `/etc/default/mdnsd` now binds it to `br0`, the only interface with an
  address and the one the default route uses. After the change, on the same
  board: **zero reloads in ninety seconds, and 8 kB of growth.**

### Added

- **`mdnsd-guard`**, run every five minutes from cron. Restarts mdnsd if its
  resident set passes 20 MB, and logs the size that triggered it.

  A net under the fix above, not a substitute for it. The leak is upstream's
  and still present; only its trigger has been removed. On a board with no
  watchdog, where the failure mode is losing the machine entirely, a threshold
  check that does nothing on a healthy system is cheap insurance — and if it
  ever fires, the log line is the field evidence that something still reloads.


## [v2.12.0] — 2026-09-09

### Fixed

- **A serial console could reboot the board by accident.** The kernel boots
  with `console=ttyS0` and a BREAK on that line triggers SysRq, with the next
  byte taken as the command. USB-serial adapters assert BREAK whenever a port
  is opened, closed or reconfigured, and nothing guarded it. The kernel's own
  help for `MAGIC_SYSRQ_SERIAL` describes the hazard exactly: *"a disconnected
  TTL level serial which can generate some garbage that can lead to spurious
  false sysrq detects."*

  The first instinct was to mask the dangerous commands off. That was the wrong
  trade: this board has **no watchdog**, so a serial reset is the only remedy
  short of walking to the rack, and it is worth keeping.

  So the trigger is guarded rather than the commands removed.
  `MAGIC_SYSRQ_SERIAL_SEQUENCE="sysrq"` means a BREAK on its own now does
  nothing; the sequence must follow it before any command is accepted. Garbage
  cannot produce that and a person typing it means it. The full command set
  stays available:

      BREAK, then "sysrq", then the key
        b  reboot        o  power off      s  sync
        w  blocked tasks m  memory         t  all tasks

  `S00sysrq` sets the runtime value to match, so the intent is visible in the
  init scripts and not only in a kernel config.

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
