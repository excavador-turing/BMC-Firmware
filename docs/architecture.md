# Where things live

The daemon, the interface and the listeners: what runs where on the board, why
it is arranged that way, and what was considered and declined. Decided on
2026-09-09. Every number below was read from board A running **v2.15.0** that
day, and the reasoning rests on those numbers; if they move, revisit it.

## The board, measured

| | measured | read from |
|---|---|---|
| RAM | 118,984 kB, of which ~88 MB available at idle; **no swap** | `/proc/meminfo` |
| bmcd | 13.0 MB binary; 18.4 MB resident fourteen minutes after boot | `/usr/bin/bmcd`, `/proc/<pid>/status` |
| interface bundle | 924 kB, served by bmcd from `/srv/bmcd/www` | `du` |
| `tpi` | 4.4 MB | `/usr/bin/tpi` |
| NAND | 2040 eraseblocks of 124 KiB; **5 free** (620 KiB) | `ubinfo /dev/ubi0` |
| UBI volumes | `uboot-env` 1, `rootfs` 370, `rootfs_prev` 370, `overlay` 1250 eraseblocks | `ubinfo -a` |
| rootfs slot | 46,981,120 bytes; the v2.15.0 OTA image is 37,773,312 bytes, **80 %**; the build fails at 90 % | release assets, `genimage.cfg` |
| overlay | 151 MiB, 116 KiB used | `df /mnt/overlay` |
| `/tmp` | 58 MB tmpfs | `df /tmp` |
| listeners | 22 (ssh), 80, 443 (bmcd: API and interface), 9110 (bmcd: metrics) | `netstat -tln` |
| a release build | 23, 18 and 24 minutes for v2.13.0, v2.14.0 and v2.15.0 | GitHub Actions |
| the promotion gate | **4 s** from tentative boot to verdict, over five consecutive promotions | `/mnt/overlay/postupdate.log` |

## What ships, and from where

One image carries everything. Nothing executable is installed outside it.

| component | repository | pinned in | on the board |
|---|---|---|---|
| the daemon, `bmcd` | `excavador-turing/bmcd` | `tp2bmc/package/bmcd/bmcd.mk` — by commit, plus the sha256 of the vendored crate archive | `/usr/bin/bmcd`, on the read-only erofs root |
| the interface | `excavador-turing/BMC-UI` | `tp2bmc/package/bmc-ui/bmc-ui.mk` — by release URL and sha256 | `/srv/bmcd/www`, served by bmcd on 443 |
| `tpi` | `excavador-turing/tpi` | `tp2bmc/package/tpi/tpi.mk` — by commit | `/usr/bin/tpi`, built with the `localhost` feature |
| the promotion gate | this repository | `tp2bmc/board/tp2bmc/overlay/etc/init.d/S99postupdate`, tested by `tests/gate.sh` | runs once per boot after bmcd: the daemon answers, every switch port exists, the version matches the staged note, `/metrics` answers on 9110 |
| settings, notes, anything that must survive a rollback | — | — | `/mnt/overlay`, the one UBI volume **both** A/B images mount |

v2.15.0 pins bmcd at v2.27.0, the interface at v3.17.0 and `tpi` at v1.4.0.
The interface's API types are generated from the bmcd release named in
`BMC-UI/bmcd-release.txt`, so a bmcd change that alters the API is followed by
an interface release, and the firmware pins both together.

## Decisions

**One daemon.** A second daemon beside bmcd — for metrics, for the console,
for anything — means inter-process communication, two authentication surfaces,
two audit paths and a second resident set on a board with 88 MB to spare.
Everything the board does goes through bmcd.

**One bundle.** The daemon and the interface ship inside the firmware image and
are tested together by the A/B gate; on a board there is no version skew
between them. An overlay-installed copy of either, updatable without a firmware
release, was considered and declined. It would trade about twenty minutes of CI
per release for three versions to reason about (the image's, the overlay's, the
one being installed), a writable executable path on the management plane, and a
gate that no longer covers the thing that changes most. Development iteration
is served another way: the daemon's `www:` setting points it at any directory,
and Buildroot's `local.mk` override builds the firmware from a working tree.

**No third slot.** Five free eraseblocks. A third rootfs volume would have to be
carved from the overlay, which is a reflash of every board and reinvents the
overlay under another name.

**One origin for the interface and the API.** A browser calling an API with
credentials must be same-origin, so the interface and `/api/bmc` share port
443. Splitting them would mean CORS for nothing. On the LAN the board serves
both; behind the tunnel the fleet UI (below) serves the interface and is itself
the API's client.

**Metrics on their own plain listener.** `/metrics` is on port 9110, plain
HTTP, no credential. The token it used to take existed so that a scrape config
could not also reach `/api/bmc`; a listener that serves nothing but `/metrics`
gives the same property without a secret to mint, store, rotate or leak. TLS
went with it: the board's certificate could never be verified, so it was a
handshake per scrape for nothing. The network is the boundary.

**The local listener becomes a Unix socket.** Today `/api/bmc` skips
authentication for `127.0.0.1`, which is how the on-board `tpi` and the gate
work — and also how any process on the board can power off a module. The
replacement is a Unix socket authenticated by peer credentials, so the loopback
bypass can be removed rather than narrowed. Planned, not shipped (SQU-165).

**Code-first API.** The Rust types are the contract; `bmcd --openapi` derives
the OpenAPI 3.1 document from them; the document is published with each bmcd
release; the interface's TypeScript types are generated from it, and CI fails
on drift. Never the other way round.

## The fleet UI is the exposure surface

Exposing a board through the tunnel — a hostname, a certificate, an Envoy route
and two policies per board, for a thing that can flash every module — was the
plan until 2026-09-09. It is not any more.

A second interface, running as a pod in the cluster, talks to every board over
the management LAN and is the only thing Envoy exposes. The tunnel route points
at the pod, never at a board. The pod authenticates to each board with a client
certificate from the internal CA, never with a stored password; bmcd verifies
the certificate and enforces authorization on what it asserts, so a compromised
pod is bounded by its certificate.

What it does not change: one daemon, one bundle. The board keeps its whole
interface on the LAN as the break-glass path, because the fleet UI depends on
the cluster it exists to recover.

What it costs: version skew becomes designed-in. The fleet UI talks to boards on
different firmware at once, so it tolerates absent and null alike on every
reading and states the range of bmcd releases it supports.

Tracked as SQU-182; the client-certificate trust in bmcd as SQU-136.

## Declined, with the reason

- **JSON-RPC.** Envoy authorises per path and JSON-RPC has one; per-operation
  authorisation would mean inspecting bodies. It also discards the HTTP status
  semantics and the aliased paths, while the legacy `?opt=&type=` form has to
  stay for upstream `tpi` regardless.
- **ConnectRPC.** Keeps per-route authorisation, but the legacy form must stay,
  so there would be three spellings of every operation; the Rust server
  ecosystem is thin; bmcd is an actix fork kept diffable against upstream. The
  two places REST is awkward — the console stream and the flash upload — do not
  justify a transport migration.
- **Spec-first server generation.** Generators produce axum, not actix; it
  would rewrite thirty-five working handlers to arrive at what code-first
  already gives.
- **An overlay-installed daemon or interface, or a third UBI slot.** Above.
- **A second daemon.** Above.
- **Four ports** (API, metrics, login, interface). Login is a POST on the same
  origin on the LAN and does not exist on the tunnel route; the interface and
  the API must share an origin. Only `/metrics` moved.

## When you change something

- **A bmcd change reaches a board only through a pin bump.** Recompute the
  vendored archive's hash inside the build container, from a tree with **no
  `local.mk`**: the hash is toolchain-dependent, and one computed with an
  override in place describes your workstation.
- **A new listener is a change to the gate**: `S99postupdate` and
  `tests/gate.sh`, where the expected port is a literal so the test cannot
  follow the script it checks. Then the scrape and the network policy on the
  cluster side.
- **Anything that grows the image** is measured against the 90 % gate from a CI
  build. A local incremental build can carry files a package stopped shipping;
  see the README's "trap when a package's file set shrinks".
- **Anything that must survive a rollback** goes on `/mnt/overlay`, and must
  tolerate being read by the *previous* image after one.
