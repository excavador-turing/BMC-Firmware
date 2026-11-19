# TP2 BMC — kernel patch log & production migration

Maintainer notes for Linux **6.18.50** (Buildroot `tp2bmc_defconfig`).  
Patch inventory: `tp2bmc/scripts/kernel-patch-tool.sh inventory`.

**See also:** [`BMC-Firmware-dev-docs/tp2-network-uboot-kernel.md`](../../../../BMC-Firmware-dev-docs/tp2-network-uboot-kernel.md) — U-Boot vs kernel network split, SMI migration gap, open U-Boot follow-ups.

---

## SMI mux — production status (2026-07-02)

**Merged** into `tp2bmc_defconfig` + `sun8i-t113s-turing-pi2.dtsi` (GPIO SMI on shared PE12/PE13).

Hardware-validated before promotion (`tp2bmc_smi_mux_poc_defconfig`, now removed):

- GPIO SMI + `tpi-i2c-smi-arbiter` on shared PE12/PE13
- RTL8370MB-CG probe, DSA ports (`node1`–`ge1`), `br0` + DHCP
- EEPROM @ `0x50` and RTC @ `0x51` on HW I²C after switch traffic
- Node link on powered slot (`node2` 1G, carrier + `dmesg` link events)

Retired: RTK-over-I²C switch @ `0x5c`, `realtek-smi-i2c`, mv64xxx NOSTART chain (i2c 0002–0005).

---

## Production migration matrix

**Status: completed 2026-07-02** on branch `feat/buildroot-2026.02-pinctrl`.

Legend: **KEEP** carry in tree · **DROP** remove after step · **REPLACE** superseded by upstream · **MERGE** fold into main files · **SUBMIT** send upstream

### Phase A — kernel config (`linux_defconfig`) — **DONE**

| Item | Current production | Target production | Action |
|------|-------------------|-------------------|--------|
| `CONFIG_NET_DSA_REALTEK_SMI` | off | `y` | **MERGE** |
| `CONFIG_NET_DSA_REALTEK_SMI_I2C` | `y` | off | **DROP** |
| `CONFIG_TPI_I2C_SMI_ARBITER` | absent | `y` | **MERGE** |
| `CONFIG_I2C_GPIO` | off | off | unchanged |
| `BR2_LINUX_KERNEL_PATCH` | no `tp2/tpi-smi-mux` | include `tp2/tpi-smi-mux` | **MERGE** |

PoC defconfig (`linux_smi_mux_poc_defconfig`, `tp2bmc_smi_mux_poc_defconfig`) → **DROPPED** (Phase D).

### Phase B — device tree (`sun8i-t113s-turing-pi2.dtsi`) — **DONE**

| Item | Current | Target | Action |
|------|---------|--------|--------|
| `ethernet-switch@5c` on `&i2c2` | RTK I²C child | deleted | **DROP** |
| `switch@smi` platform node | in `*-smi-mux.dtsi` only | in `.dtsi` for all boards | **MERGE** from `sun8i-t113s-turing-pi2-smi-mux.dtsi` |
| `tpi-i2c-smi-arb` | PoC overlay | in `.dtsi` | **MERGE** |
| `&i2c2` `pinctrl-names` | `default` only | `default`, `smi_mode` + empty `pinctrl-1` | **MERGE** |
| `sun8i-t113s-turing-pi2-v2.5.2-smi-mux.dts` | PoC model string | remove; use standard v2.5.2 DTS | **DROP** |
| `sun8i-t113s-turing-pi2-smi-mux.dtsi` | separate include | contents → `.dtsi` | **DROP** file after merge |

### Phase C — FIT / image build — **DONE**

| Item | Current PoC | Target production | Action |
|------|-------------|-------------------|--------|
| `turing-pi2-poc.its` | smi-mux FIT config | standard ITS only | **DROP** |
| `boot-poc.scr` / `install-poc.scr` | config override | standard `boot.scr` | **DROP** |
| `poc_build.sh` gating | PoC branch detection | remove | **DROP** |
| `post_build.sh` / `post_image.sh` PoC paths | conditional smi-mux DTB | build smi-mux DTB from merged `.dtsi` or drop extra DTB name | **MERGE** |

### Phase D — patch directories — **DONE**

#### `patches/linux/tp2/tpi-smi-mux/` (0001–0003)

| Patch | Purpose | Production |
|-------|---------|------------|
| 0001 | DT binding arbiter | **KEEP** (until upstream binding) |
| 0002 | arbiter driver (incl. shared-pin probe / pinctrl / pin release formerly 0004–0006) | **KEEP** (TP2-specific) |
| 0003 | realtek-smi shared-bus bracket | **KEEP** |

**Removed from tree:** former `0004`–`0006` (folded into `0001`–`0003`). PoC DTS/defconfigs/scripts dropped.

Add directory to `BR2_LINUX_KERNEL_PATCH` in `tp2bmc_defconfig` (order: `generic/i2c` → `generic/pwm` → `net-dsa` → `tp2/gpio` → `tp2/power` → `tp2/tpi-smi-mux`).  
Long-term: **SUBMIT** arbiter + binding upstream (optional).

#### `patches/linux/net-dsa/`

| Patch | Purpose | Production |
|-------|---------|------------|
| 0001 | Backport `realtek_forward` through net-next `660a9e399ab0`: bridge, FDB, VLAN, bridge flags, `tag_rtl8_4` REASON handling | **KEEP** until shipped kernel includes the series |
| 0002 | RTL8370MB-CG `0x6368/0x0010` chip row | **KEEP** until upstream adds chip row · **SUBMIT** |
| 0003 | HW LAG/trunk offload (`port_lag_*`, dumb-mode trunk, LACP RMA trap); replaces unused HSR ops | **KEEP** |
| 0004 | LAG bridge uplink fixups (isolation, EFID, VLAN filtering guard, FDB CPU→lag remap) | **KEEP** (TP2 topology) |
| 0005 | PHY autoneg kick on node ports | **KEEP** (TP2 quirk) |
| 0006 | Key FDB entries for the learning mode the lookup uses (`ivl = vid != 0`) | **KEEP** · **SUBMIT** (fixes upstream `realtek_forward`) |

**Removed from tree (superseded — do not re-add):** `0001-net-dsa-tag_rtl8_4-*` (in backport `0001`), old `0002` i2c_addr, duplicate `0003` chip row, `0004` RTK-over-I²C, old `0005` bridge offload, `0006` smi-i2c NOSTART doc, monolithic LAG+fixup `0003-net-dsa-rtl8365mb-hw-lag-bridge-uplink.patch`.

#### `patches/linux/generic/i2c/` (mv64xxx)

| Patch | Purpose | Production SMI |
|-------|---------|----------------|
| 0001 | clear bus errors before xfer | **KEEP** — EEPROM/RTC robustness |
| 0002 | clean up private struct | **DROPPED** — only needed for removed NOSTART chain |
| 0003 | FSM refactor | **DROPPED** — only needed for removed NOSTART chain |
| 0004 | continue after read | **DROPPED** — only needed for removed NOSTART chain |
| 0005 | `I2C_FUNC_NOSTART` / EFR | **DROPPED** — only for removed RTK-over-I²C switch |

Production retains **0001** only unless bench shows regressions without 0002–0004.

#### `patches/linux/tp2/power/` / `tp2/gpio/` / `generic/pwm/`

| Path | Purpose | Production |
|------|---------|------------|
| `tp2/power/0001` | regulator-fixed `preserve-boot-state` | **KEEP** (TP2 warm-reboot) |
| `tp2/power/0002` | gpio-latch SRAM shadow @ `0x0709010c` | **KEEP** (TP2 SPL contract; not mainline-generic) |
| `tp2/gpio/0001` | gpio-aggregator `turing,pi2-nodes` | **KEEP** |
| `generic/pwm/0001–0003` | Allwinner D1/T113 PWM | **KEEP** until upstream |

Former combined `power/0001-power-regulator-fixed-gpio-latch-…` was split into `0001`+`0002` above.

---

## Upstream monitor — `realtek_forward` (bridge / VLAN / FDB offload)

**Backported locally.** When it lands in a kernel version we ship, drop local `net-dsa/0001` and keep only the RTL8370MB-CG chip row if still missing upstream.

| Field | Value |
|-------|--------|
| Series name | `realtek_forward` |
| Subject | `net: dsa: realtek: rtl8365mb: bridge offloading and VLAN support` |
| Author | Luiz Angelo Daros de Luca (based on Alvin Šipraga) |
| v1 Message-ID | `20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com` |
| v1 link | https://patch.msgid.link/20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com |
| Latest tracked | **v13** (2026-06-06) |
| LWN summary | https://lwn.net/Articles/1076755/ |
| Target tree | `linux-net-next` → expect **6.19+** (not in 6.18.33 mainline; locally backported) |
| change-id | `20260323-realtek_forward-1bac3a77c664` |

### What the local backport adds (replacing old `net-dsa/0005`)

- `port_bridge_{join,leave}` via **isolation masks + EFID** (no dot1x trap hack)
- HW **FDB** + `fdb_isolation`, assisted learning on CPU port
- HW **VLAN** filtering / PVID offload
- Bridge port flags; driver split (`rtl8365mb_main/l2/vlan/table.c`, `rtl83xx` ops)
- `tag_rtl8_4` updates (accepted upstream separately and included in local backport)

### What upstream does **not** include (still ours)

- **RTL8370MB-CG** chip table row (`0x6368` / `0x0010`) — keep **`net-dsa/0002`** or submit separately
- **Hardware LAG / trunk** (`port_lag_join`) — keep **`net-dsa/0003`–`0005`**; not in `realtek_forward`
- **`tpi-i2c-smi-arbiter`** / shared PE12/PE13 — TP2-only
- **`realtek-smi-i2c`** — we are dropping this path

### Mode 4 — VLAN DB on LAG members (fixed in `0004`)

`realtek_forward` VLAN offload targets **DSA user ports in the bridge**.
With `bond0` on `br0`, `ge0`/`ge1` are bond slaves, so `port_vlan_add` never
ran for the ASIC trunk ports (Mode 3 flat `ge0` trunk was fine; Mode 4 leaked
untagged native DHCP alongside tagged VLAN DHCP).

**Fix in `0004`:** `rtl8365mb_lag_sync_uplink_vlans()` mirrors `bond0`’s bridge
VLAN DB onto each lag member via `port_vlan_filtering` + `port_vlan_add`,
called from lag refresh and `rtl8365mb_lag_bridge_fixup_refresh()` (after
`tp2-net-config` applies VLANs). Validate with LAN DHCP enabled: nodes must
get only `.10.x`/`.20.x`; `tcpdump -ni lagg0` must not see untagged node DHCP.

### Mode 2 — LACP data plane on the HW trunk (2026-08-31)

Mode 2 (802.3ad `ge0`+`ge1`, flat `br0`, DHCP) had **two independent bugs**
that presented as one. Both are fixed; the sequence below is recorded because
several plausible-looking theories cost days and should not be re-tried.

**Bug 1 — partner LACPDUs never reached bonding.** With the HW trunk
programmed, the ASIC consumes slow-protocol frames itself, so
`/proc/net/bonding/bond0` stayed at `ports: 1` with a zero partner MAC.
Fix: `rtl8365mb_rma_trap_lacp()` in `0003` writes `RMA_CTRL02` (`0x0802`) to
trap `01:80:c2:00:00:02` to the CPU. Linux runs LACP, the ASIC only
aggregates the data plane (dumb mode).

**Bug 2 — VLAN filtering against an empty VLAN table.**
`rtl8365mb_lag_sync_uplink_vlans()` called `port_vlan_filtering(ge0/ge1, true)`
whenever `bond0` sat on a bridge, **without checking whether the bridge was
VLAN filtering**. In Mode 2 `br0` is flat, so `br_vlan_get_info()` failed for
every VID and no membership was programmed — while ingress *and* egress
membership checks were now enforced (the driver also clears transparent-VLAN
toward every other port). The ASIC dropped everything from the uplink except
RMA-trapped frames.

This is why the failure looked so contradictory: **LACP converged perfectly,
ARP/DHCP left the box, OPNsense answered on `lagg0`, and nothing ever arrived
on `ge0`/`ge1`.** It is also why forcing `lag_can_offload` false appeared to
"fix" it — with no `lag_member_pmask` the fixup and VLAN sync never ran.
Fix: follow the bridge via `br_vlan_enabled()`; log and return early when flat.

**Obsolete workaround removed.** `0005` used to clear `skb->offload_fwd_mark`
in `tag_rtl8_4` for all non-LAG ingress while a LAG was active, so the
software bridge would forward node traffic to `bond0`. That existed only
because the ASIC could not forward (Bug 2) and it **forces every node frame
through the 100M CPU port**: measured 94 Mbit/s node→WAN with ~120 MB in each
direction on the conduit for a 112 MB transfer. Removed; the mark is left at
DSA's default so the bridge skips software forwarding and the trunk carries
node traffic in hardware.

**Verified on hardware (kernel 6.18.38, OPNsense `lagg0` = `igb0`+`igb2`):**

| Check | Result |
|-------|--------|
| `/proc/net/bonding/bond0` | `ports: 2`, partner `00:0d:b9:49:07:38`, Collecting+Distributing |
| BMC → gateway / `8.8.8.8` | 0% loss |
| Node → WAN conduit bytes | 11 KB over a 10 s iperf (was 243 MB) — ASIC switched |
| Node → WAN throughput | 207–249 Mbit/s — ceiling is the OPNsense appliance, not the trunk |

**Dead ends — do not re-try:**

- *Disabling learning on lag members.* Did not help; CPU-tagged TX already
  sets `LEARN_DIS` in the tag. Leaves the ASIC unable to learn uplink MACs,
  so all node→WAN unicast floods and a benchmark can look fast while being
  wrong.
- *Pinning the conduit MAC on a lag member instead of the CPU port.* Replies
  entering on that member are dropped (ingress == egress) and replies on the
  other member are sent back out the uplink. DHCP stops completely.
- *Blaming the `0003`/`0004`/`0005` patch split, tag/mark policy, or dumb
  mode* for the LACP RX failure. None were involved.

**Measured — the conduit MAC pin never worked, and BMC traffic floods.**
`rtl8365mb_lag_pin_conduit_mac()` logged `LAG: pinned … on cpu port 4 efid 1`
on every fixup, yet with it active both node1 and node2 captured the
gateway's ICMP echo replies addressed to the BMC. `bridge fdb show dev <port>
self`, which dumps the ASIC table, holds the attached module MACs on node1
and node2 and the two OPNsense port MACs on ge0/ge1, but the BMC's
`c4:ff:84:10:00:ba` appears on no port at all. The control confirms the
mechanism: node1's MAC *is* in hardware, and traffic to it never reached
node2. So an address with an FDB entry is switched, and the BMC's address —
never learned, because CPU-injected TX sets `LEARN_DIS` — is unknown unicast
and floods to every node. The pin has been removed from `0004`.

**Closed — the ~207 Mbit/s ceiling is the OPNsense appliance.** Later runs
reached 249 Mbit/s, and disconnecting one of the two trunk cables left
throughput unchanged. A single member still offers a full gigabit, so a
figure that does not move when the trunk is halved is not set by the trunk,
the LAG hash or the ASIC — it is the router terminating the WAN path. This
also explains why the same ~209 Mbit/s appears in earlier logs from runs that
*were* genuine ASIC offload. Use node→node iperf, which never leaves the
switch, as the reference for ASIC line rate.

(`ethtool` is **not** in the image; add `BR2_PACKAGE_ETHTOOL=y` before any
future PHY/pause/counter debugging.)

### Closed — BMC unicast flooded every node port: FDB entries keyed for the wrong learning mode (2026-09-07)

Every frame addressed to the BMC was delivered to all four node ports, letting
nodes passively observe BMC management traffic. The cause was **`0006`**: the
driver wrote every FDB entry as IVL while the hardware, on a flat bridge, looks
up SVL.

`rtl8365mb_l2_add_uc()` set `uc.key.ivl = true` unconditionally. IVL is only
meaningful for VLANs actually programmed into the 4K table, which happens
solely from `rtl8365mb_vlan_4k_port_add()`. Every other VLAN — including
VLAN-unaware traffic on vid 0 — keeps the chip default of shared learning on
FID 0, which is also how the ASIC learns addresses on its own. So driver
entries landed in a key space the lookup never consults. They read back
perfectly from the L2 table while remaining invisible to forwarding, and the
BMC's address stayed unknown unicast forever.

The fix keys each entry the way the lookup that must find it will be keyed:
`ivl = vid != 0`. Verified against hardware in both learning modes — the
driver's keys now match what the ASIC learns by itself:

| Bridge mode | ASIC learns | Driver writes |
|-------------|-------------|---------------|
| Flat `br0` (Mode 2) | `ivl=0 vid=0` | `ivl=0 vid=0` |
| VLAN filtering (Mode 4) | `ivl=1 vid=10/20` | `ivl=1 vid=1/10/20` |

**Measured, flat Mode 2, BMC pinging the gateway, all node ports linked:**

| Port | Before (100 pings) | After (200 pings) |
|------|--------------------|-------------------|
| node1 | 10528 B | 0 B |
| node2 | flooded | 0 B |
| node3 | flooded | 0 B |
| `eth0` (conduit) | 11046 B | 21464 B |

`tcpdump -i eth0 icmp` on node1 captured 0 packets during the ping. Delete
symmetry confirmed: a static entry added with `bridge fdb add … dev node3
master static` appeared as `ivl=0 vid=0 dst=2 static=1` and left no residue
after `bridge fdb del`.

Sample every port across **one** ping burst, not one burst per port. Unknown
unicast floods to every port in the domain, so the signature of the bug is a
node port tracking the conduit byte for byte, and the signature of a healthy
switch is every port at zero simultaneously. Sequential per-port sampling
occasionally catches a single ARP broadcast (60–140 B on one port) that has
nothing to do with this bug.

**Why the earlier theory was wrong.** The previous entry in this log concluded
the key was fine and blamed the CPU port for not being a valid `l2_add_uc`
destination. Both halves were wrong: `dst=4` (CPU) was accepted and stored
correctly all along, and the key was the only defect. The entries were present,
correct-looking and inert — which is precisely why dumping the ASIC table
through `bridge fdb show … self` (user ports only) could never reveal it. What
finally isolated it was a temporary debug patch dumping every L2 entry per port
*including the CPU port*, then comparing a learned entry against a
driver-written one: identical but for `ivl`.

**Diagnostic note.** Two things made this expensive. `bridge fdb show dev …
self` cannot show CPU-port entries, so the table looked empty of the BMC's MAC
when it was in fact populated. And `CONFIG_DYNAMIC_DEBUG` was off, compiling
out the driver's `dev_dbg` traces of every FDB write. It is now `=y` in
`linux_defconfig`.

### Mode 4 (VLAN + LACP) — verified on hardware (2026-09-07, reconfirmed 2026-09-09)

Exercises `0004`'s `rtl8365mb_lag_sync_uplink_vlans()` in the mirroring
direction.

Config: node1+node2 access VLAN 10, node3 access VLAN 20, `bond0` trunk with
native VLAN 1 plus 10 and 20, `br0` on the native VLAN.

| Check | Result |
|-------|--------|
| VLAN mirroring onto lag members | `LAG VLAN sync: mirrored 3 VLAN(s) from bond0 onto members 0x60` |
| Node DHCP across the trunk | node1 `192.168.10.107` (VLAN 10); node3 `192.168.20.102` (`ip addr` on the node, 2026-09-09) |
| Intra-VLAN throughput (node1→node2) | 945 Mbit/s (2026-09-07) |
| Cross-subnet ping node1→node3 | `192.168.10.107` → `192.168.20.102`: 100% loss |
| Same-subnet ASIC isolation | node3 secondary `192.168.10.250/24`; node1 `ping`/`arping` from `192.168.10.107`: 0 replies (2026-09-10). ASIC does not flood VLAN 10 onto the VLAN 20 access port. |
| BMC control plane | unaffected on the native VLAN throughout |
| Mode 4 → Mode 2 transition | `LAG VLAN sync: bond0 not VLAN filtering; members transparent` |

**Apply order (2026-09-09).** `tp2-net-config apply` used to `ifup` first (LAG
sync while `vlan_filtering=0` → `members transparent`), then program the Linux
VLAN table. `0004` only copies `bond0`'s VID set onto `ge0`/`ge1` on
`port_bridge_join`. Nodes then leased native `192.168.1.x`. Workaround: bounce
an unused `br0` member (`node4` leave/join). Overlay now calls
`tp2-lag-bridge-fixup-refresh.sh vlan-sync` after `apply_vlans`.

The ASIC isolation test puts both nodes in the **same subnet** on different
access VLANs. A `192.168.10.x` ↔ `192.168.20.x` ping goes to the router first
and does not prove L2 membership.

**BMC native VLAN after LAG VLAN sync.** `bridge vlan show` on a failed Mode 4
apply had `br0` VLAN 1 *without* `PVID Egress Untagged`. Host ARP left untagged
and replies stayed tagged (`ip neigh … FAILED`). Cause: `apply_port_vlan`
re-added `vid 1 self` on `br0` after `apply_br0_host_pvid`, which strips those
flags. Native VID is now added as `pvid untagged self`, and host PVID is
applied last.

Note that a flood test run in Mode 4 is meaningless: node ports are not members
of the BMC's VLAN, so membership blocks the flood before the FDB is consulted.
Mode 2 is the only configuration in which the `0006` fix is observable.

### Observability — checks that passed without verifying anything (2026-09-08)

`CONFIG_LOG_BUF_SHIFT=14` gave a 16 KiB kernel ring buffer that wrapped past
the boot banner within ~34 s of uptime. Every `hw-validate` check asserting the
*absence* of a boot message — the D section, plus the arbiter and switch probe
lines — therefore reported results it had not verified: D1/D2/D3/D5 turned
green on an empty buffer, while F1 and G1 turned red.

Fixed on both sides. `CONFIG_LOG_BUF_SHIFT=17` (128 KiB) keeps the boot log for
the life of a session, and `hw-validate` now gates every absence check on
`boot_log_present()`, reporting SKIP rather than a pass it cannot justify.
F1 and G1 gained dmesg-independent fallbacks (a bound device under
`/sys/bus/platform/drivers/tpi-i2c-smi-arbiter`; the presence of DSA user
ports), and the LAG fixup and VLAN sync checks distinguish "no LAG event in
this buffer" from "the patch is missing". The bump also fixed B3, which had
been reporting an unattributed WARN for the same reason.

`0004`'s mirrored-VLAN message was `dev_dbg` while its transparent counterpart
was `dev_info`, so Mode 4 success was invisible to the validator while Mode 2
success was loud. Both are `dev_info` now.

### Adoption checklist (run when series appears in `git tag v6.x`)

1. `tp2bmc/scripts/kernel-patch-tool.sh history` (or the same checks by hand): confirm files in `drivers/net/dsa/realtek/`, `net/dsa/tag_rtl8_4.c` match series.
2. Bump `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` to that release.
3. **Remove** local `net-dsa/0001-net-dsa-realtek-rtl8365mb-backport-bridge-fdb-vlan-offload.patch`.
4. **Keep** local `net-dsa/0002` until `chip_id == 0x6368` probe works without it.
5. Confirm `tag_rtl8_4` REASON/forward logic is in-tree before removing the backport.
6. Rebuild; run regression: switch probe, `br0`, inter-node throughput (HW hairpin vs CPU), VLAN if used.
7. Update **Monitor log** below with merge commit / kernel version.

### Monitor log (append on check)

| Date | Kernel / tree | Series version | In mainline? | Local action |
|------|---------------|----------------|--------------|--------------|
| 2026-09-11 | 6.18.50 | Pin bump 6.18.48 → 6.18.50 | **No** | `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE`; local `net-dsa` series still required. Drop leftover `ATOMIC64_SELFTEST` / `PM_DEBUG` / `PM_ADVANCED_DEBUG` / `PROFILING`. Keep `DEBUG_FS` + `DYNAMIC_DEBUG`. `0001` `rtl83xx.c` hunk 3: match 6.18.50 `gpiod_set_value_cansleep` in `rtl83xx_reset_deassert`. |
| 2026-09-10 | 6.18.48 | Mode 4 same-subnet isolation | **No** | node3 `192.168.10.250` + `192.168.20.102`; node1 arping/ping `.250`: 0 replies |
| 2026-09-09 | 6.18.48 | Mode 4 VLAN assign + LAG VLAN sync after apply | **No** | node1 `192.168.10.107`, node3 `192.168.20.102` after `node4` leave/join; apply now retriggers `vlan-sync` |
| 2026-09-07 | 6.18.48 | FDB learning-mode keying (`net-dsa/0006`) | **No** | `ivl = vid != 0`; ends BMC unicast flooding to node ports. Mode 2 and Mode 4 both verified on hardware; candidate for upstream submission against `realtek_forward` |
| 2026-08-31 | 6.18.38 | Mode 2 LACP data plane (`net-dsa/0003`–`0005`) | **No** | LACP RMA trap + VLAN filtering guard; dropped `offload_fwd_mark` clear-all (CPU hairpin). Node→WAN ASIC switched; 207–249 Mbit/s ceiling traced to the OPNsense appliance |
| 2026-07-04 | 6.18.33 | HW LAG offload (`net-dsa/0003`) | **No** | `port_lag_*` + RTL8367C trunk tables for `ge0`+`ge1` bond |
| 2026-07-03 | 6.18.33 | `realtek_forward` merged in net-next through `660a9e399ab0` | **No** | Backported locally as `net-dsa/0001`; old minimal `0005` dropped |
| 2026-07-02 | 6.18.33 | `realtek_forward` v13 on net-next | **No** | Production SMI migration merged; keep `net-dsa/0001`+`0005` until upstream lands |

**Next review:** when bumping past 6.18.x — grep upstream `rtl8365mb` for `port_bridge_join`, `rtl8365mb_l2.c`, `max_num_bridges`.

```bash
# Quick check in a linux.git clone
git fetch origin tag v6.19  # or current target
git log v6.18.50..v6.19 --oneline -- drivers/net/dsa/realtek/ net/dsa/tag_rtl8_4.c
git grep -l port_bridge_join v6.19 -- drivers/net/dsa/realtek/
```

---

## Implementation order (production SMI) — **completed**

1. ~~**Phase B**~~ — smi-mux merged into `sun8i-t113s-turing-pi2.dtsi`; `@5c` switch removed.
2. ~~**Phase A**~~ — `linux_defconfig` + `tp2bmc_defconfig` patch path.
3. ~~**Phase D**~~ — dropped `net-dsa` 0002, 0004, 0006; dropped `i2c` 0002–0005 (kept 0001).
4. ~~**Phase C**~~ — single FIT/boot flow; PoC scripts/defconfigs removed.
5. **Bench** (on hardware): EEPROM, RTC, all node ports, `br0` DHCP, cross-node `iperf`, FDB/VLAN lab checks.
6. On next kernel bump: execute **Upstream monitor** adoption checklist below.

---

## Test plan (production image)

- [ ] `dmesg`: arbiter on `2502800.i2c`, RTL8370MB-CG found, DSA tree setup
- [ ] No PE12 pin conflict; no `pm_runtime` underflow
- [ ] `hexdump` EEPROM MAC matches `br0`
- [ ] `hwclock -r` sane after reboot
- [ ] Per-node: power on → `carrier==1` → link in `dmesg`
- [ ] `br0` DHCP; `ge1` / uplink as today
- [ ] (Optional) `iperf` node↔node — baseline before upstream offload merge
