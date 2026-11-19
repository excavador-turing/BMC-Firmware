#!/bin/sh
# Hardware validation — excavador hive line (default kernel 6.12.109; set EXPECTED_KERNEL for 6.18.x later)
# On BMC (login shell PATH includes /usr/share/tp2):
#   hw-validate.sh --mac aa:bb:cc:dd:ee:ff | tee /tmp/hw-validate.log
#   EXPECTED_BOARD_MAC=… hw-validate.sh
#   hw-validate.sh --mode 4 --mac …
# Manual / opt-in: E (MSD matrix), B2 (screen UART), C2 (static IP),
#   UPLINK_HAIRPIN_TEST=1 (G6 iperf hairpin)

set -u

PASS_N=0
FAIL_N=0
WARN_N=0
SKIP_N=0

usage() {
	cat <<'EOF'
Usage: hw-validate.sh [OPTIONS] [ADDR]

  --mac ADDR     Expected factory board MAC on br0 (also: first positional arg)
  --mode N       Assert network profile N (1=flat, 2=LACP, 3=VLAN flat, 4=VLAN+LACP)
  ADDR           Same as --mac when the value contains ':'

Environment:
  EXPECTED_BOARD_MAC     Same as --mac
  HW_VALIDATE_MODE       Same as --mode
  UPLINK_HAIRPIN_TEST=1  Run G6 iperf hairpin helper (needs powered node)

Exit status: 0 if no FAIL lines; 1 otherwise.
EOF
}

normalize_mac() {
	printf '%s' "$1" | tr 'A-F' 'a-f'
}

mac_oui_prefix() {
	printf '%s' "$1" | awk -F: '{ if (NF >= 3) print $1":"$2":"$3; }'
}

EXPECTED_KERNEL=${EXPECTED_KERNEL:-6.12.109}
EXPECTED_BOARD_MAC=${EXPECTED_BOARD_MAC:-}
VALIDATE_MODE=${HW_VALIDATE_MODE:-}

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	--mac)
		if [ $# -lt 2 ]; then
			echo "hw-validate.sh: --mac requires an address" >&2
			exit 1
		fi
		EXPECTED_BOARD_MAC=$2
		shift 2
		;;
	--mode)
		if [ $# -lt 2 ]; then
			echo "hw-validate.sh: --mode requires 1–4" >&2
			exit 1
		fi
		VALIDATE_MODE=$2
		shift 2
		;;
	-*)
		echo "hw-validate.sh: unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		if [ -z "$EXPECTED_BOARD_MAC" ] && printf '%s' "$1" | grep -q ':'; then
			EXPECTED_BOARD_MAC=$1
			shift
		else
			echo "hw-validate.sh: unexpected argument: $1" >&2
			usage >&2
			exit 1
		fi
		;;
	esac
done

case "$VALIDATE_MODE" in
''|1|2|3|4) ;;
*)
	echo "hw-validate.sh: --mode must be 1, 2, 3, or 4 (got $VALIDATE_MODE)" >&2
	exit 1
	;;
esac

if [ -n "$EXPECTED_BOARD_MAC" ]; then
	EXPECTED_BOARD_MAC=$(normalize_mac "$EXPECTED_BOARD_MAC")
	EXPECTED_BOARD_OUI=$(mac_oui_prefix "$EXPECTED_BOARD_MAC")
fi

REPORT=/tmp/hw-validate-"$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)".log

pass() { PASS_N=$((PASS_N + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL_N=$((FAIL_N + 1)); printf 'FAIL  %s\n' "$1"; }
warn() { WARN_N=$((WARN_N + 1)); printf 'WARN  %s\n' "$1"; }
skip() { SKIP_N=$((SKIP_N + 1)); printf 'SKIP  %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

section() {
	printf '\n=== %s ===\n' "$1"
}

kernel_ok() {
	kr=$1
	case "$EXPECTED_KERNEL" in
	*.x)
		prefix=${EXPECTED_KERNEL%.x}
		case "$kr" in
		"$prefix"*) return 0 ;;
		*) return 1 ;;
		esac
		;;
	*)
		[ "$kr" = "$EXPECTED_KERNEL" ] && return 0
		# Also accept any 6.18.* when expect is 6.18.38 (minor stable bumps)
		case "$EXPECTED_KERNEL" in
		6.18.*)
			case "$kr" in
			6.18.*) return 0 ;;
			esac
			;;
		esac
		return 1
		;;
	esac
}

# Drop by-tpi symlinks whose /dev/sdX block device no longer exists (E3 / RockUSB).
cleanup_stale_by_tpi_links() {
	dir=/dev/disk/by-tpi
	[ -d "$dir" ] || return 0
	for n in 1 2 3 4; do
		link="${dir}/node${n}"
		[ -L "$link" ] || continue
		target=$(readlink "$link" 2>/dev/null) || continue
		bname=${target#/dev/}
		[ -n "$bname" ] || continue
		if [ ! -d "/sys/block/${bname}" ]; then
			rm -f "$link"
			info "E3 removed stale ${link} (block ${bname} gone)"
		fi
	done
}

find_i2c_device() {
	addr=$1
	for dev in /sys/bus/i2c/devices/*-"$addr"; do
		[ -e "$dev/name" ] || continue
		printf '%s\n' "$dev"
		return 0
	done
	return 1
}

format_mac_hex() {
	printf '%s' "$1" | sed 's/../&:/g; s/:$//'
}

read_eeprom_mac() {
	eeprom_file=$1
	if command -v hexdump >/dev/null 2>&1; then
		dd if="$eeprom_file" bs=1 skip=44 count=6 2>/dev/null \
			| hexdump -v -e '6/1 "%02x" "\n"'
	elif command -v od >/dev/null 2>&1; then
		dd if="$eeprom_file" bs=1 skip=44 count=6 2>/dev/null \
			| od -An -tx1 | tr -d ' \n'
	else
		return 1
	fi
}

netdev_master() {
	dev=$1
	if [ -e "/sys/class/net/$dev/master" ]; then
		basename "$(readlink "/sys/class/net/$dev/master" 2>/dev/null)"
	fi
}

tcpdump_probe() {
	# "tcpdump -c 1" blocks until a packet arrives, so bound it: reaching the
	# timeout still proves the capture was opened.
	_rc=0
	if command -v timeout >/dev/null 2>&1; then
		timeout 5 tcpdump -i "$1" -c 1 >/dev/null 2>&1 || _rc=$?
	else
		tcpdump -i "$1" -c 1 >/dev/null 2>&1 || _rc=$?
	fi
	case $_rc in
		0) echo opened ;;
		124|137) echo timeout ;;
		*) echo rejected ;;
	esac
}

conduit_netdev() {
	# eth0 on current images; sun8i-emac enumerates as end0 under some
	# kernel/DT combinations. Override with UPLINK_CONDUIT.
	for c in ${UPLINK_CONDUIT:-} eth0 end0; do
		[ -n "$c" ] || continue
		[ -d "/sys/class/net/$c" ] || continue
		printf '%s\n' "$c"
		return 0
	done
	return 1
}

conf_get() {
	# Best-effort: last matching key=value outside comments in network.conf
	key=$1
	file=${2:-/etc/tp2/network.conf}
	[ -r "$file" ] || return 1
	grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2- | tr -d ' \t\r'
}

has_bond0_lacp() {
	[ -d /sys/class/net/bond0 ] && [ -r /proc/net/bonding/bond0 ] \
		&& grep -q "802.3ad" /proc/net/bonding/bond0 2>/dev/null
}

# dmesg is a ring buffer and `dmesg -c` drains it. Checks that assert the
# *absence* of a boot message turn green once the boot log is gone, reporting a
# pass they never verified. Gate those on the banner still being present; a
# positive match is always conclusive and needs no gate.
boot_log_present() {
	dmesg 2>/dev/null | grep -q 'Linux version '
}

lag_fixup_seen() {
	dmesg 2>/dev/null | grep -q "LAG bridge uplink fixup" && return 0
	# Durable marker if summary was compiled as dbg-only on older images
	dmesg 2>/dev/null | grep -q "LAG bridge fixup:" && return 0
	[ -x /etc/network/tp2-lag-bridge-fixup-refresh.sh ] || return 1
	return 1
}

# Last VLAN sync decision wins: dmesg keeps history across mode switches.
#
# The log is the only observable here: ge0/ge1 are bond slaves rather than
# bridge ports, so `bridge vlan show` never lists them even though DSA has
# programmed their VLAN membership into the ASIC. When no sync line is in the
# buffer, distinguish "no LAG event happened while this buffer was alive" from
# "a fixup ran but stayed silent" — only the latter says anything about the
# driver.
lag_vlan_sync_last() {
	dmesg 2>/dev/null | grep "LAG VLAN sync" | tail -1
}

lag_vlan_sync_unobservable() {
	[ -z "$(lag_vlan_sync_last)" ] && ! lag_fixup_seen && ! boot_log_present
}

# Same trap for the fixup itself: an empty buffer reads as a missing patch.
lag_fixup_unobservable() {
	! lag_fixup_seen && ! boot_log_present
}

# Flat br0 (Mode 1–2): members must stay transparent, or the ASIC enforces
# membership against an empty VLAN table and drops all uplink traffic.
lag_vlan_transparent() {
	lag_vlan_sync_last | grep -q "members transparent"
}

lag_vlan_mirrored() {
	line=$(lag_vlan_sync_last)
	[ -n "$line" ] || return 1
	printf '%s' "$line" | grep -q "members transparent" && return 1
	return 0
}

# --- A: image sanity ---
section "A — Image and toolchain"
kr=$(uname -r 2>/dev/null || echo unknown)
if kernel_ok "$kr"; then
	pass "A1 uname -r = $kr"
else
	fail "A1 uname -r = $kr (expected $EXPECTED_KERNEL)"
fi

if command -v tpi >/dev/null 2>&1; then
	pass "A2 tpi present: $(tpi --version 2>/dev/null | head -1)"
else
	fail "A2 tpi not in PATH"
fi

if pidof bmcd >/dev/null 2>&1 || [ -x /usr/bin/bmcd ]; then
	pass "A2 bmcd: $(pidof bmcd 2>/dev/null || echo binary present)"
else
	warn "A2 bmcd not running (may start later)"
fi

# Firmware / build identity when present on the image
if [ -r /etc/os-release ]; then
	info "A3 $(grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null | tr '\n' ' ')"
fi
if [ -r /etc/tp2/build-id ]; then
	pass "A3 build-id: $(cat /etc/tp2/build-id 2>/dev/null)"
elif [ -r /usr/share/doc/turing-pi-bmc/buildroot-output-build-dir-listing.txt ]; then
	info "A3 BOM listing present under /usr/share/doc/turing-pi-bmc/"
else
	info "A3 no /etc/tp2/build-id — use build-host git rev-parse"
fi

# --- B: QoL packages ---
section "B — tcpdump, screen, NAND, SysRq"
if command -v tcpdump >/dev/null 2>&1; then
	pass "B1 tcpdump: $(tcpdump --version 2>/dev/null | head -1)"
	case $(tcpdump_probe lo) in
		opened|timeout) pass "B1 tcpdump can capture on lo" ;;
		*)              fail "B1 tcpdump cannot capture on lo" ;;
	esac
	_cap=$(conduit_netdev || echo eth0)
	case $(tcpdump_probe "$_cap") in
		opened|timeout) warn "B1 tcpdump -i $_cap opened the capture (doc says the rtl8_4 tag may make this fail)" ;;
		*)              pass "B1 tcpdump -i $_cap rejected as expected (use br0/ge*/node*)" ;;
	esac
else
	fail "B1 tcpdump missing"
fi

if command -v screen >/dev/null 2>&1; then
	pass "B2 screen: $(screen -v 2>/dev/null | head -1)"
	for n in 1 2 3 4; do
		[ -x "/usr/bin/node$n" ] && pass "B2 /usr/bin/node$n exists" || warn "B2 /usr/bin/node$n missing"
	done
	skip "B2 interactive UART — run: node1 (Ctrl-A k to quit)"
else
	fail "B2 screen missing"
fi

if dmesg 2>/dev/null | grep -qi '256.*MiB\|MX35LF2'; then
	pass "B3 SPI NAND 256 MiB (v2.5.x class)"
elif dmesg 2>/dev/null | grep -qi '128.*MiB\|MX35LF1'; then
	pass "B3 SPI NAND 128 MiB (v2.4 class)"
else
	warn "B3 SPI NAND size — check: dmesg | grep -i nand"
fi

sysrq=$(sysctl -n kernel.sysrq 2>/dev/null || cat /proc/sys/kernel/sysrq 2>/dev/null)
if [ "$sysrq" = "0" ]; then
	pass "B4 kernel.sysrq = 0"
else
	warn "B4 kernel.sysrq = ${sysrq:-?} (expected 0 on cold boot)"
fi
grep -q 'kernel.sysrq' /etc/sysctl.conf 2>/dev/null \
	&& pass "B4 /etc/sysctl.conf has sysrq" \
	|| warn "B4 no sysrq in /etc/sysctl.conf"

# --- C: br0 / MAC ---
section "C — br0 / factory MAC (#238)"
if ip link show br0 >/dev/null 2>&1; then
	br_mac=$(ip -br link show br0 2>/dev/null | awk '{print $3}')
	br_ip=$(ip -br addr show br0 2>/dev/null | awk '{print $3}')
	pass "C1 br0 up: mac=$br_mac addr=$br_ip"
	br_mac=$(normalize_mac "$br_mac")
	if [ -n "$EXPECTED_BOARD_MAC" ]; then
		if [ "$br_mac" = "$EXPECTED_BOARD_MAC" ]; then
			pass "C1 board MAC matches expected"
		else
			case "$br_mac" in
			"${EXPECTED_BOARD_OUI}"*)
				pass "C1 factory OUI on br0 (expected prefix $EXPECTED_BOARD_OUI)"
				;;
			*)
				fail "C1 br0 MAC $br_mac (expected $EXPECTED_BOARD_MAC)"
				;;
			esac
		fi
	else
		case "$br_mac" in
		02:00:*) fail "C1 br0 still locally administered ($br_mac) — check apply_bmc_mac / S39bmc-mac" ;;
		esac
		skip "C1 factory MAC check — pass --mac ADDR or EXPECTED_BOARD_MAC"
	fi
else
	fail "C1 br0 missing"
fi

[ -f /etc/network/apply_bmc_mac.sh ] \
	&& pass "C1 apply_bmc_mac.sh present ($(wc -c </etc/network/apply_bmc_mac.sh) bytes)" \
	|| fail "C1 apply_bmc_mac.sh missing"
[ -f /etc/init.d/S39bmc-mac ] && pass "C1 S39bmc-mac present" || warn "C1 S39bmc-mac missing"
[ -x /etc/network/set_br0_mac_pre_dhcp.sh ] \
	&& pass "C1 set_br0_mac_pre_dhcp.sh present" \
	|| fail "C1 set_br0_mac_pre_dhcp.sh missing"
# Hook lives in interfaces.d profiles (e.g. 00-br0-flat), not the top-level interfaces file.
# Under a bond profile it is deliberately inert — set_br0_mac_pre_dhcp.sh returns early and
# apply_bmc_mac refuses to touch br0, because br0 inherits its MAC from the bond slaves.
# Check the property the hook exists to guarantee instead of the hook itself.
if [ -f /etc/network/interfaces.d/10-bond-lacp ]; then
	factory_mac=$(. /etc/network/apply_bmc_mac.sh 2>/dev/null; read_bmc_mac 2>/dev/null)
	br0_mac=$(cat /sys/class/net/br0/address 2>/dev/null)
	if [ -z "$factory_mac" ]; then
		warn "C1 bond profile: factory MAC unreadable (NVMEM/EEPROM), br0=${br0_mac:-none}"
	elif [ "$factory_mac" = "$br0_mac" ]; then
		pass "C1 bond profile: br0 carries factory MAC $br0_mac (hook not applicable)"
	else
		fail "C1 bond profile: br0 MAC ${br0_mac:-none} != factory $factory_mac"
	fi
elif grep -rq set_br0_mac_pre_dhcp /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null; then
	pass "C1 pre-up set_br0_mac_pre_dhcp wired for br0"
else
	fail "C1 set_br0_mac_pre_dhcp not referenced in interfaces(.d) — MAC may miss first DHCP"
fi

if grep -q apply_bmc_mac /var/log/messages 2>/dev/null; then
	pass "C1 apply_bmc_mac logged on boot"
else
	warn "C1 no apply_bmc_mac in /var/log/messages (syslog empty?)"
fi

skip "C2 static br0 + ping — lab-only manual"
skip "C3 SD tpi.ini MAC — optional manual"

# --- D: boot hygiene ---
section "D — Boot log / kconfig"
boot_log_present || skip "D boot log rotated or cleared (dmesg -c) — absence checks D1/D2/D3/D5 cannot be verified; reboot and rerun"

if dmesg 2>/dev/null | grep -F 'sunxi_ccu_probe' | grep -q 'No max_rate, ignoring min_rate'; then
	fail "D1 #249 sunxi_ccu_probe No max_rate line present"
elif boot_log_present; then
	pass "D1 no #249 sunxi_ccu No max_rate spam"
fi

if dmesg 2>/dev/null | grep -F 'Fixed dependency cycle' | grep -qE 'mixer@|tcon-top@|lcd-controller@'; then
	fail "D2 DE display dependency-cycle flood still present"
elif boot_log_present; then
	pass "D2 no mixer/tcon/lcd dependency-cycle flood"
fi
dmesg 2>/dev/null | grep -F 'Fixed dependency cycle' | grep -q 'rtc@7090000' \
	&& info "D2 CCU↔RTC cycles present (expected noise)" || true

if dmesg 2>/dev/null | grep -qE 'exFAT-fs|F2FS-fs'; then
	warn "D3 exFAT/F2FS messages in dmesg (review if BMC root card)"
elif boot_log_present; then
	pass "D3 no exFAT/F2FS fs noise in dmesg"
fi

if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_F2FS_FS=' && fail "D4 CONFIG_F2FS_FS=y" || pass "D4 CONFIG_F2FS_FS off"
	zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_EXFAT_FS=' && fail "D4 CONFIG_EXFAT_FS=y" || pass "D4 CONFIG_EXFAT_FS off"
elif [ -f "/boot/config-${kr}" ]; then
	grep -q '^CONFIG_F2FS_FS=y' "/boot/config-${kr}" && fail "D4 F2FS=y" || pass "D4 F2FS off"
else
	skip "D4 kconfig — no /proc/config.gz"
fi

# GS0 inittab spam regression
if grep -qE '^GS0::respawn:' /etc/inittab 2>/dev/null; then
	fail "D5 GS0 getty still in inittab (expect mdev/S11bmc-otg only)"
elif dmesg 2>/dev/null | grep -q 'Id "GS0" respawning too fast'; then
	warn "D5 GS0 respawn spam still in dmesg (old image or leftover)"
elif boot_log_present; then
	pass "D5 no GS0 inittab respawn / no GS0 spam in dmesg"
else
	pass "D5 no GS0 getty in inittab (dmesg half of the check unavailable)"
fi

# --- E: MSD symlinks (static checks only) ---
section "E — #225 MSD by-tpi (static + manual)"
[ -x /usr/bin/mdev-tpi-msd-symlink ] && pass "E mdev-tpi-msd-symlink installed" || fail "E helper missing"
grep -q mdev-tpi-msd-symlink /etc/mdev.conf 2>/dev/null && pass "E mdev.conf hook" || fail "E mdev.conf hook missing"
cleanup_stale_by_tpi_links
if [ -d /dev/disk/by-tpi ]; then
	ls -la /dev/disk/by-tpi/ 2>/dev/null | while read -r line; do info "$line"; done
	pass "E /dev/disk/by-tpi exists"
	for n in 1 2 3 4; do
		link=/dev/disk/by-tpi/node${n}
		[ -L "$link" ] || continue
		tgt=$(readlink -f "$link" 2>/dev/null || true)
		if [ -n "$tgt" ] && [ -b "$tgt" ]; then
			pass "E node${n} -> $tgt"
		else
			warn "E node${n} symlink stale/broken"
		fi
	done
else
	info "E /dev/disk/by-tpi absent until MSD — manual per node:"
	info "  tpi advanced msd -nN"
	info "  ls -la /dev/disk/by-tpi/"
	info "  readlink -f /dev/disk/by-tpi/nodeN"
	info "  tpi advanced normal -nN"
fi
skip "E1–E4 full matrix — one node at a time (msd/normal per node)"

# --- F: I2C shared bus ---
section "F — I2C / EEPROM / RTC / SMI arbiter"
if dmesg 2>/dev/null | grep -qi 'arbiter on .*i2c'; then
	pass "F1 tpi-i2c-smi-arbiter probe: $(dmesg 2>/dev/null | grep -i 'arbiter on .*i2c' | tail -1)"
elif [ -d /sys/bus/platform/drivers/tpi-i2c-smi-arbiter ] \
	&& ls -1 /sys/bus/platform/drivers/tpi-i2c-smi-arbiter 2>/dev/null \
		| grep -qvE '^(bind|unbind|uevent|module)$'; then
	pass "F1 tpi-i2c-smi-arbiter bound (sysfs; probe line no longer in dmesg)"
elif boot_log_present; then
	fail "F1 no tpi-i2c-smi-arbiter probe line in dmesg"
else
	skip "F1 arbiter probe — boot log gone and driver not bound in sysfs"
fi

if eeprom_dev=$(find_i2c_device 0050); then
	eeprom_name=$(cat "$eeprom_dev/name" 2>/dev/null || echo unknown)
	pass "F2 EEPROM present: $(basename "$eeprom_dev") name=$eeprom_name"
	if [ -r "$eeprom_dev/eeprom" ]; then
		eeprom_mac_hex=$(read_eeprom_mac "$eeprom_dev/eeprom" 2>/dev/null || true)
		if [ "${#eeprom_mac_hex}" = 12 ]; then
			eeprom_mac=$(normalize_mac "$(format_mac_hex "$eeprom_mac_hex")")
			pass "F2 EEPROM MAC read: $eeprom_mac"
			if [ -n "$EXPECTED_BOARD_MAC" ]; then
				if [ "$eeprom_mac" = "$EXPECTED_BOARD_MAC" ]; then
					pass "F2 EEPROM MAC matches expected"
				else
					warn "F2 EEPROM MAC $eeprom_mac differs from expected $EXPECTED_BOARD_MAC"
				fi
			fi
		else
			fail "F2 EEPROM read failed or returned ${#eeprom_mac_hex} hex chars"
		fi
	else
		fail "F2 EEPROM sysfs data file missing at $eeprom_dev/eeprom"
	fi
else
	fail "F2 EEPROM @0x50 missing from /sys/bus/i2c/devices"
fi

if rtc_i2c_dev=$(find_i2c_device 0051); then
	pass "F3 RTC I2C device present: $(basename "$rtc_i2c_dev") name=$(cat "$rtc_i2c_dev/name" 2>/dev/null || echo unknown)"
else
	board_model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
	case "$board_model" in
	*"v2.4"*) skip "F3 RTC @0x51 not expected on v2.4 base DT" ;;
	*) fail "F3 RTC @0x51 missing from /sys/bus/i2c/devices" ;;
	esac
fi

rtc_found=0
for rtc in /sys/class/rtc/rtc*; do
	[ -e "$rtc/name" ] || continue
	rtc_name=$(cat "$rtc/name" 2>/dev/null || echo unknown)
	case "$rtc_name" in
	*pcf8563*|*PCF8563*)
		rtc_found=1
		rtc_dev="/dev/$(basename "$rtc")"
		pass "F3 external RTC present: $(basename "$rtc") name=$rtc_name"
		if command -v hwclock >/dev/null 2>&1; then
			rtc_time=$(hwclock -f "$rtc_dev" -r 2>/dev/null || hwclock -r 2>/dev/null || true)
			if [ -n "$rtc_time" ]; then
				pass "F3 RTC read: $rtc_time"
				printf '%s' "$rtc_time" | grep -q '20[2-9][0-9]' \
					|| warn "F3 RTC time did not include a modern year"
			else
				fail "F3 hwclock could not read $rtc_dev"
			fi
		elif [ -r "$rtc/time" ] && [ -r "$rtc/date" ]; then
			pass "F3 RTC sysfs read: $(cat "$rtc/date" 2>/dev/null) $(cat "$rtc/time" 2>/dev/null)"
		else
			fail "F3 no hwclock and no readable RTC sysfs time"
		fi
		;;
	esac
done
if [ "$rtc_found" = 0 ]; then
	board_model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
	case "$board_model" in
	*"v2.4"*) skip "F3 external PCF8563 RTC not expected on v2.4 base DT" ;;
	*) fail "F3 external PCF8563 RTC not found" ;;
	esac
fi

if emc_dev=$(find_i2c_device 002f); then
	pass "F4 optional EMC2301 present: $(basename "$emc_dev") name=$(cat "$emc_dev/name" 2>/dev/null || echo unknown)"
else
	warn "F4 optional EMC2301 @0x2f not present (normal unless v2.4 fan mod is populated)"
fi

if dmesg 2>/dev/null | grep -qi 'realtek-smi-i2c\|rtl8365mb-i2c\|I2C_FUNC_NOSTART'; then
	fail "F5 retired RTK-over-I2C/NOSTART path still appears in dmesg"
else
	pass "F5 no retired RTK-over-I2C/NOSTART path in dmesg"
fi

# --- G: DSA smoke ---
section "G — DSA / switch / network interfaces"
if dmesg 2>/dev/null | grep -qi 'RTL8370'; then
	pass "G1 RTL8370MB in dmesg"
elif [ -d /sys/class/net/node1 ] && [ -d /sys/class/net/ge0 ]; then
	# DSA creates these netdevs only after the switch probes, so their
	# presence proves the driver bound — it just cannot confirm the chip ID.
	pass "G1 DSA user ports present, switch bound (chip ID line no longer in dmesg)"
elif boot_log_present; then
	fail "G1 no RTL8370 in dmesg"
else
	skip "G1 switch identification — boot log gone and no DSA user ports"
fi
for p in br0 node1 node2 node3 node4 ge0 ge1; do
	if ip link show "$p" >/dev/null 2>&1; then
		master=$(netdev_master "$p")
		state=$(cat "/sys/class/net/$p/operstate" 2>/dev/null || echo unknown)
		carrier=$(cat "/sys/class/net/$p/carrier" 2>/dev/null || echo n/a)
		info "G2 netdev: $p state=$state carrier=$carrier master=${master:-none}"
		pass "G2 netdev present: $p"
	else
		fail "G2 netdev missing: $p"
	fi
done
if conduit=$(conduit_netdev); then
	state=$(cat "/sys/class/net/$conduit/operstate" 2>/dev/null || echo unknown)
	info "G2 CPU conduit netdev: $conduit state=$state"
else
	warn "G2 no CPU conduit netdev found (tried eth0, end0; set UPLINK_CONDUIT)"
fi
ip link show br0 2>/dev/null | grep -q UP && pass "G2 br0 UP" || warn "G2 br0 not UP"

for p in node1 node2 node3 node4 ge0 ge1; do
	if ip link show "$p" >/dev/null 2>&1; then
		master=$(netdev_master "$p")
		if [ "$p" = ge0 ] || [ "$p" = ge1 ]; then
			if [ -d /sys/class/net/bond0 ]; then
				[ "$master" = bond0 ] && pass "G3 $p enslaved to bond0" \
					|| warn "G3 $p master=${master:-none} (expected bond0 with LACP profile)"
			else
				[ "$master" = br0 ] && pass "G3 $p enslaved to br0" \
					|| warn "G3 $p master=${master:-none} (expected br0)"
			fi
		else
			[ "$master" = br0 ] && pass "G3 $p enslaved to br0" \
				|| warn "G3 $p master=${master:-none} (expected br0)"
		fi
	fi
done

for p in ge1 eth0 end0; do
	if ip link show "$p" >/dev/null 2>&1; then
		speed=$(cat "/sys/class/net/$p/speed" 2>/dev/null || echo ?)
		info "G4 $p speed=${speed}Mb/s"
	fi
done

if command -v bridge >/dev/null 2>&1; then
	bridge_detail=$(bridge -d link show 2>/dev/null || true)
	if printf '%s\n' "$bridge_detail" | grep -qi offload; then
		pass "G5 bridge link reports offload marker"
	else
		skip "G5 bridge link has no visible offload marker (often not exposed by this kernel/iproute2)"
	fi

	if dmesg 2>/dev/null | grep -qiE 'rtl8365mb.*(lag|trunk).*(fail|error)|port_lag.*EOPNOTSUPP'; then
		fail "G5 LAG offload-related error in dmesg"
	elif has_bond0_lacp \
		&& grep -q "ge0" /proc/net/bonding/bond0 2>/dev/null \
		&& grep -q "ge1" /proc/net/bonding/bond0 2>/dev/null; then
		if lag_fixup_seen; then
			pass "G5 bond0 802.3ad ge0+ge1 + LAG bridge uplink fixup (net-dsa/0004)"
		elif lag_fixup_unobservable; then
			skip "G5 LAG bridge uplink fixup — no LAG event in the current dmesg buffer"
		else
			warn "G5 bond0 802.3ad ge0+ge1 but no LAG fixup in dmesg — node WAN may cap at ~100M via eth0; need net-dsa/0004"
		fi
		if lag_vlan_transparent; then
			pass "G5 LAG VLAN sync: members transparent (flat br0 path)"
		elif lag_vlan_mirrored; then
			pass "G5 LAG VLAN sync: trunk VLANs mirrored (Mode 4 path)"
		elif lag_vlan_sync_unobservable; then
			skip "G5 LAG VLAN sync — no LAG event in the current dmesg buffer"
		elif [ -r /sys/class/net/br0/bridge/vlan_filtering ] \
			&& [ "$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null)" = 1 ]; then
			warn "G5 vlan_filtering=1 + bond0 but no 'LAG VLAN sync' in dmesg yet"
		fi
	elif [ -d /sys/class/net/bond0 ]; then
		warn "G5 bond0 present but not 802.3ad ge0+ge1 (HW LAG not exercised)"
	else
		info "G5 no bond0 configured (HW LAG not exercised; see README Modes 2/4)"
	fi

	if dmesg 2>/dev/null | grep -qiE 'rtl8365mb.*bridge.*(fail|error)|dsa.*bridge.*(fail|error)'; then
		fail "G5 bridge offload-related error in dmesg"
	else
		pass "G5 no bridge offload-related errors in dmesg"
	fi

	if [ -r /sys/class/net/br0/bridge/vlan_filtering ]; then
		vlan_filtering=$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null)
		if [ "$vlan_filtering" = 1 ]; then
			if [ -d /sys/class/net/bond0 ]; then
				info "G5 br0 vlan_filtering=1 with bond0 (Mode 4 — check LAG VLAN sync above)"
			else
				pass "G5 br0 vlan_filtering=1 (Mode 3 VLAN/PVID path)"
			fi
		else
			info "G5 br0 vlan_filtering=0 (flat / Mode 1–2 default)"
		fi
	fi

	fdb_detail=$(bridge -d fdb show br br0 2>/dev/null || bridge -d fdb show 2>/dev/null || true)
	if printf '%s\n' "$fdb_detail" | grep -qi offload; then
		pass "G5 bridge FDB reports offloaded entries"
	else
		info "G5 no offloaded FDB entries visible yet (generate traffic, then rerun bridge -d fdb show br br0)"
	fi
else
	skip "G5 bridge command missing; cannot inspect bridge offload markers"
fi

section "G6 — bond uplink hairpin (needs powered node + traffic)"
if has_bond0_lacp; then
	conduit=$(conduit_netdev || echo eth0)
	conduit_speed=$(cat "/sys/class/net/$conduit/speed" 2>/dev/null || echo ?)
	info "G6 $conduit (CPU port) speed=${conduit_speed}Mb/s — must not carry switched node WAN traffic"
	if [ -r /var/run/tp2-uplink-test-eth0-delta ]; then
		delta=$(cat /var/run/tp2-uplink-test-eth0-delta 2>/dev/null || echo 0)
		max=${UPLINK_ETH0_DELTA_MAX:-67108864}
		if [ "$delta" -gt "$max" ] 2>/dev/null; then
			fail "G6 $conduit hairpin delta=${delta} bytes (>${max}) — node WAN via CPU ~100M; need net-dsa/0004"
		else
			pass "G6 $conduit hairpin delta=${delta} bytes (uplink likely ASIC-switched)"
		fi
	elif [ "${UPLINK_HAIRPIN_TEST:-0}" = 1 ] && [ -x /usr/share/tp2/uplink-hairpin-test.sh ]; then
		info "G6 running uplink-hairpin-test (start node iperf during wait)..."
		if /usr/share/tp2/uplink-hairpin-test.sh; then
			pass "G6 uplink-hairpin-test passed"
		else
			fail "G6 uplink-hairpin-test failed"
		fi
	else
		skip "G6 run: UPLINK_HAIRPIN_TEST=1 hw-validate.sh (node: iperf3 -c <gw> -t10 during wait)"
		info "G6 expect node iperf ~900+ Mbit/s; ~88 Mbit/s = eth0 hairpin without 0004"
	fi
else
	skip "G6 no bond0 802.3ad — uplink hairpin test N/A (flat br0 uses ge0/ge1 on bridge)"
fi

# --- H: USB ---
section "H — USB gadget / routing"
board_model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
info "H board model: ${board_model:-unknown}"

if [ -d /sys/class/udc ] && ls /sys/class/udc 2>/dev/null | grep -q .; then
	pass "H1 UDC present: $(ls /sys/class/udc 2>/dev/null | tr '\n' ' ')"
else
	warn "H1 no UDC in /sys/class/udc"
fi

if [ -d /sys/kernel/config/usb_gadget/g1 ]; then
	pass "H1 usb_gadget g1 configured"
else
	warn "H1 usb_gadget g1 missing (S11bmc-otg not started?)"
fi

if [ -c /dev/ttyGS0 ]; then
	pass "H1 /dev/ttyGS0 present (ACM gadget)"
else
	info "H1 /dev/ttyGS0 absent until gadget bound — OK if OTG unused"
fi

if command -v tpi >/dev/null 2>&1; then
	usb_st=$(tpi usb status 2>/dev/null || true)
	if [ -n "$usb_st" ]; then
		pass "H2 tpi usb status"
		info "H2 $usb_st"
	else
		warn "H2 tpi usb status returned empty (auth/API?)"
	fi
else
	skip "H2 tpi missing — cannot query USB route"
fi

case "$board_model" in
*"v2.5"*|*"v2.6"*)
	info "H3 v2.5+: USB-A is Node1-only; 4×NODE OTG via tpi usb device|flash -n N (no --bmc)"
	;;
*"v2.4"*)
	info "H3 v2.4: USB-A mux can target any one node (tpi usb host|device -n N)"
	;;
esac
skip "H3 interactive USB host/device matrix — manual per node"

# --- I: power / GPIO ---
section "I — Power / node GPIOs"
if command -v tpi >/dev/null 2>&1; then
	pwr=$(tpi power status 2>/dev/null || true)
	if [ -n "$pwr" ]; then
		pass "I1 tpi power status"
		info "I1 $(printf '%s' "$pwr" | tr '\n' ' ' | cut -c1-120)"
	else
		warn "I1 tpi power status empty"
	fi
else
	skip "I1 tpi missing"
fi

gpio_ok=0
for chip in /sys/bus/gpio/devices/*/of_node/gpio-line-names \
	/sys/devices/platform/*/gpio/*/of_node/gpio-line-names; do
	[ -r "$chip" ] || continue
	names=$(tr '\0' '\n' <"$chip" 2>/dev/null | grep -E 'node[1-4]-(en|rpiboot|usbotg)' | head -5)
	if [ -n "$names" ]; then
		gpio_ok=1
		pass "I2 gpio-line-names include node lines"
		info "I2 sample: $(printf '%s' "$names" | tr '\n' ' ')"
		break
	fi
done
# Fallback: gpioinfo if present
if [ "$gpio_ok" = 0 ] && command -v gpioinfo >/dev/null 2>&1; then
	if gpioinfo 2>/dev/null | grep -q 'node1-en'; then
		gpio_ok=1
		pass "I2 gpioinfo shows node1-en"
	fi
fi
if [ "$gpio_ok" = 0 ]; then
	# sysfs gpiochip label / consumer names
	if grep -rqs 'node1-en' /sys/kernel/debug/gpio 2>/dev/null \
		|| ls /sys/class/gpio/ 2>/dev/null | grep -q .; then
		warn "I2 could not confirm node*-en line names (debugfs/gpioinfo limited)"
	else
		warn "I2 no gpio-line-names found for node*-en"
	fi
fi

if ls /sys/class/regulator/ 2>/dev/null | grep -qE 'slot|atx|regulator'; then
	pass "I3 regulators present under /sys/class/regulator"
else
	info "I3 no obvious slot/atx regulators in sysfs names"
fi

# Optional v2.5 pwm-fan
if ls /sys/class/pwm/pwmchip* >/dev/null 2>&1; then
	pass "I4 pwmchip present"
elif [ -d /sys/class/hwmon ]; then
	info "I4 no pwmchip (fan may be hwmon-only or absent)"
else
	info "I4 no pwmchip / hwmon"
fi

# --- Mode profile assertions ---
if [ -n "$VALIDATE_MODE" ]; then
	section "M — Mode $VALIDATE_MODE profile"
	vlan_f=0
	[ -r /sys/class/net/br0/bridge/vlan_filtering ] \
		&& vlan_f=$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null || echo 0)
	bond_en=0
	has_bond0_lacp && bond_en=1

	case "$VALIDATE_MODE" in
	1)
		[ "$bond_en" = 0 ] && pass "M1 no LACP bond0" || fail "M1 bond0 802.3ad present (expected flat Mode 1)"
		[ "$vlan_f" = 0 ] && pass "M1 vlan_filtering=0" || fail "M1 vlan_filtering=$vlan_f (expected 0)"
		for p in ge0 ge1; do
			m=$(netdev_master "$p")
			[ "$m" = br0 ] && pass "M1 $p on br0" || warn "M1 $p master=${m:-none}"
		done
		;;
	2)
		[ "$bond_en" = 1 ] && pass "M2 bond0 802.3ad" || fail "M2 no bond0 802.3ad"
		[ "$vlan_f" = 0 ] && pass "M2 vlan_filtering=0" || warn "M2 vlan_filtering=$vlan_f (Mode 2 usually 0)"
		bm=$(netdev_master bond0)
		[ "$bm" = br0 ] && pass "M2 bond0 on br0" || fail "M2 bond0 master=${bm:-none} (expected br0)"
		if lag_fixup_seen; then
			pass "M2 LAG bridge uplink fixup seen"
		elif lag_fixup_unobservable; then
			skip "M2 LAG bridge uplink fixup — no LAG event in the current dmesg buffer"
		else
			warn "M2 no LAG fixup in dmesg (rebuild / apply net-dsa/0004)"
		fi
		if [ "$vlan_f" = 0 ]; then
			if lag_vlan_transparent; then
				pass "M2 lag members transparent (flat br0)"
			elif lag_vlan_mirrored; then
				fail "M2 VLAN filtering forced on ge0/ge1 with flat br0 — uplink traffic will be dropped"
			elif lag_vlan_sync_unobservable; then
				skip "M2 LAG VLAN sync — no LAG event in the current dmesg buffer"
			else
				warn "M2 no 'LAG VLAN sync' line — kernel predates the VLAN filtering guard"
			fi
		fi
		;;
	3)
		[ "$bond_en" = 0 ] && pass "M3 no LACP bond0" || fail "M3 bond0 present (Mode 3 is flat uplink)"
		[ "$vlan_f" = 1 ] && pass "M3 vlan_filtering=1" || fail "M3 vlan_filtering=$vlan_f (expected 1)"
		if command -v bridge >/dev/null 2>&1; then
			bridge vlan show 2>/dev/null | grep -q . \
				&& pass "M3 bridge vlan table non-empty" \
				|| warn "M3 bridge vlan show empty — check [port.*] in network.conf"
		fi
		;;
	4)
		[ "$bond_en" = 1 ] && pass "M4 bond0 802.3ad" || fail "M4 no bond0 802.3ad"
		[ "$vlan_f" = 1 ] && pass "M4 vlan_filtering=1" || fail "M4 vlan_filtering=$vlan_f (expected 1)"
		bm=$(netdev_master bond0)
		[ "$bm" = br0 ] && pass "M4 bond0 on br0" || fail "M4 bond0 master=${bm:-none}"
		if lag_fixup_seen; then
			pass "M4 LAG bridge uplink fixup seen"
		elif lag_fixup_unobservable; then
			skip "M4 LAG bridge uplink fixup — no LAG event in the current dmesg buffer"
		else
			warn "M4 no LAG fixup in dmesg"
		fi
		if lag_vlan_mirrored; then
			pass "M4 LAG VLAN sync mirrored trunk VLANs"
		elif lag_vlan_transparent; then
			fail "M4 lag members left transparent — VLAN sync did not see br0 vlan_filtering"
		elif lag_vlan_sync_unobservable; then
			skip "M4 LAG VLAN sync — no LAG event in the current dmesg buffer; retrigger with: ip link set node4 nomaster; ip link set node4 master br0"
		else
			warn "M4 LAG fixup ran but logged no VLAN sync line — kernel predates the dev_info symmetry, or sync returned early"
		fi
		;;
	esac

	if [ -r /etc/tp2/network.conf ]; then
		info "M network.conf bond.enabled=$(conf_get enabled /etc/tp2/network.conf 2>/dev/null || conf_get 'bond.enabled' 2>/dev/null || echo ?)"
		pass "M /etc/tp2/network.conf present"
	else
		warn "M no /etc/tp2/network.conf (profile may be manual interfaces)"
	fi
else
	section "M — Mode profile"
	skip "M pass --mode 1|2|3|4 to assert flat/LACP/VLAN/VLAN+LACP"
fi

section "Summary"
info "PASS=$PASS_N FAIL=$FAIL_N WARN=$WARN_N SKIP=$SKIP_N"
info "Board: $(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')"
if [ -n "$EXPECTED_BOARD_MAC" ]; then
	info "Expected board MAC: $EXPECTED_BOARD_MAC"
fi
if [ -n "$VALIDATE_MODE" ]; then
	info "Mode assert: $VALIDATE_MODE"
fi
info "Log hint: sh $0 [--mac ADDR] [--mode N] 2>&1 | tee $REPORT"
info "Build host: git rev-parse --short HEAD"

if [ "$FAIL_N" -gt 0 ]; then
	printf '\nRESULT: FAIL (%s failures)\n' "$FAIL_N"
	exit 1
fi
printf '\nRESULT: PASS\n'
exit 0
