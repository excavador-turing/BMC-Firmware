#!/bin/sh
#
# The node MSD helper: /usr/bin/mdev-tpi-msd-symlink (#225).
#
# It names a disk /dev/disk/by-tpi/nodeN. On a board with an onboard hub (v2.5)
# the port says which node: 1-1.N or 2-1.N. On v2.4 there is no hub; the BMC
# routes one node at a time onto the root port, so the disk is on 1-1 or 2-1
# and the node is the one the USB mux selects, read from the lines bmcd holds
# (gpiochip0 offsets 192..195, listed in debugfs).
#
# The helper reads every system path under $TPI_ROOT, so a scratch tree stands
# in for /sys, /proc and /dev here.
#
# Run:  sh tests/mdev-tpi-msd-symlink.sh
#
set -u

SCRIPT=${SCRIPT:-tp2bmc/board/tp2bmc/overlay/usr/bin/mdev-tpi-msd-symlink}
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
TPI_ROOT="$work/root"
by="$TPI_ROOT/dev/disk/by-tpi"

reset() {
	rm -rf "$TPI_ROOT"
	mkdir -p "$TPI_ROOT/proc/device-tree" "$TPI_ROOT/sys/kernel/debug" \
		"$TPI_ROOT/sys/class/block" "$TPI_ROOT/sys/block" "$TPI_ROOT/dev"
	rm -f "$TPI_ROOT/sys/kernel/debug/gpio"
}

board() { printf 'Turing Pi 2 (%s)\0' "$1" > "$TPI_ROOT/proc/device-tree/model"; }

# gpio_dump BASE SEL2 SEL1 OE1 OE2: what debugfs shows with bmcd holding the
# four mux lines (offsets 192, 193, 194, 195). Other chips and other lines are
# there to be ignored.
gpio_dump() {
	b=$1
	cat > "$TPI_ROOT/sys/kernel/debug/gpio" <<EOF
gpiochip2: GPIOs 100-131, parent: platform/other, other:
 gpio-110 (                    |gpiod               ) out hi
 gpio-111 (                    |gpiod               ) out hi
 gpio-112 (                    |gpiod               ) out lo
 gpio-113 (                    |gpiod               ) out lo

gpiochip0: GPIOs ${b}-$((b + 255)), parent: platform/2000000.pinctrl, 2000000.pinctrl:
 gpio-$((b + 5))   (                    |sysfs              ) in  hi
 gpio-$((b + 192)) (                    |gpiod              ) out $2
 gpio-$((b + 193)) (                    |gpiod              ) out $3
 gpio-$((b + 194)) (                    |gpiod              ) out $4
 gpio-$((b + 195)) (                    |gpiod              ) out $5
 gpio-$((b + 196)) (                    |gpiod              ) out lo

gpiochip1: GPIOs 900-931, parent: platform/other, other:
 gpio-900 (node1-en             |gpiod              ) out hi
EOF
}

# route_to NODE [BASE]: the levels bmcd sets, as pin_controller.rs lists them
# (node 1 is 0b1100 for [SEL1, OE1, SEL2, OE2], the first line the lowest bit).
route_to() {
	b=${2:-512}
	case "$1" in
	1) gpio_dump "$b" hi lo lo hi ;;
	2) gpio_dump "$b" hi hi lo hi ;;
	3) gpio_dump "$b" lo hi hi lo ;;
	4) gpio_dump "$b" hi hi hi lo ;;
	esac
}

# disk NAME PORT: a block device whose device sits below the USB path PORT, as
# the kernel lays it out: .../usbB/<port>/<leaf>:1.0/host0/target0:0:0/0:0:0:0
disk() {
	name=$1 port=$2
	bus=${port%%-*}
	leaf=${port##*/}
	d="$TPI_ROOT/sys/devices/platform/soc/4200000.usb/usb${bus}/${port}/${leaf}:1.0/host0/target0:0:0/0:0:0:0"
	mkdir -p "$d/block/$name" "$TPI_ROOT/sys/class/block/$name" "$TPI_ROOT/sys/block/$name"
	ln -sfn "$d" "$TPI_ROOT/sys/class/block/$name/device"
}
gone() { rm -rf "$TPI_ROOT/sys/block/$1" "$TPI_ROOT/sys/class/block/$1"; }

# hdl SUBSYSTEM ACTION MDEV: one mdev event.
hdl() {
	TPI_ROOT="$TPI_ROOT" SUBSYSTEM=$1 ACTION=$2 MDEV=$3 sh "$SCRIPT"
}
add() { hdl block add "$1"; }

link_of() { readlink "$by/node$1" 2>/dev/null; }
no_links() { [ -z "$(ls "$by" 2>/dev/null)" ]; }
expect_link() { # NODE TARGET WHAT
	got=$(link_of "$1")
	[ "$got" = "$2" ] && ok "$3" || bad "$3: node$1 -> '${got}'"
}
expect_none() { # WHAT
	no_links && ok "$1" || bad "$1: $(ls "$by")"
}

echo "1. v2.5, the hub says which node: unchanged"
reset; board v2.5
disk sda 2-1/2-1.3; add sda
expect_link 3 /dev/sda "a disk on 2-1.3 is node 3"
reset; board v2.5.1
disk sda 1-1/1-1.2; add sda
expect_link 2 /dev/sda "a disk on 1-1.2 is node 2"
reset; board v2.5
route_to 4
disk sda 2-1/2-1.1; add sda
expect_link 1 /dev/sda "the mux lines are not consulted when the port names the node"
reset; board v2.5
disk sda 2-1/2-1.10; add sda
expect_none "2-1.10 is not node 1"

echo "2. v2.5, a disk on the root port is not guessed at"
reset; board v2.5
route_to 1
disk sda 2-1; add sda
expect_none "no link on a board with a hub"
reset; board v2.5.1
route_to 2
disk sda 1-1; add sda
expect_none "no link on v2.5.1 either"

echo "3. v2.4, a disk on the root port gets the node the mux routes to"
for n in 1 2 3 4; do
	for port in 2-1 1-1; do
		reset; board v2.4
		route_to "$n"
		disk sda "$port"; add sda
		expect_link "$n" /dev/sda "mux on node $n, disk on $port: node$n"
		for other in 1 2 3 4; do
			[ "$other" = "$n" ] && continue
			[ ! -e "$by/node$other" ] || bad "node$other appeared too"
		done
	done
done
reset; board v2.4
route_to 1 0
disk sda 2-1; add sda
expect_link 1 /dev/sda "a chip whose GPIOs start at 0"
reset; board v2.4
route_to 3 768
disk sda 2-1; add sda
expect_link 3 /dev/sda "a chip whose GPIOs start at 768"
reset; board v2.4
route_to 2
disk sdb 2-1; add sdb
expect_link 2 /dev/sdb "the link follows the device name"

echo "4. v2.4, the mux state cannot be told: no link rather than a wrong one"
reset; board v2.4
disk sda 2-1; add sda
expect_none "no debugfs gpio file"
reset; board v2.4
printf 'gpiochip0: GPIOs 512-767, parent: platform/2000000.pinctrl, 2000000.pinctrl:\n gpio-517 (                    |gpiod              ) out hi\n' \
	> "$TPI_ROOT/sys/kernel/debug/gpio"
disk sda 2-1; add sda
expect_none "the mux lines are not claimed"
reset; board v2.4
gpio_dump 512 hi lo lo lo
disk sda 2-1; add sda
expect_none "both muxes enabled"
reset; board v2.4
gpio_dump 512 hi lo hi hi
disk sda 2-1; add sda
expect_none "both muxes disabled"
reset; board v2.4
route_to 1
sed -i '/gpio-705 /d' "$TPI_ROOT/sys/kernel/debug/gpio"
disk sda 2-1; add sda
expect_none "a missing select line"
reset; board v2.4
route_to 1
sed -i 's/^gpiochip0: GPIOs 512-767/gpiochip0: GPIOs unknown/' "$TPI_ROOT/sys/kernel/debug/gpio"
disk sda 2-1; add sda
expect_none "a header without the first GPIO number"
reset; board v2.4
route_to 1
sed -i 's/^gpiochip0:/gpiochip7:/' "$TPI_ROOT/sys/kernel/debug/gpio"
disk sda 2-1; add sda
expect_none "the mux lines on another chip are not the mux"
reset
route_to 1
disk sda 2-1; add sda
expect_none "no device tree model"

echo "5. v2.4, a hub child path still means what it always did"
reset; board v2.4
route_to 1
disk sda 2-1/2-1.2; add sda
expect_link 2 /dev/sda "2-1.2 is node 2 whatever the mux says"

echo "6. v2.4, removal"
reset; board v2.4
route_to 2
disk sda 2-1; add sda
expect_link 2 /dev/sda "node 2 is linked"
gone sda; hdl block remove sda
expect_none "the block remove drops the link"
reset; board v2.4
route_to 1
disk sda 2-1; add sda
gone sda; hdl usb remove 2-1:1.0
expect_none "the USB remove of 2-1:1.0 drops a link whose disk is gone"
reset; board v2.4
route_to 1
disk sda 2-1; add sda
gone sda; hdl usb remove 2-1
expect_none "the USB remove of 2-1 drops it too"
reset; board v2.4
route_to 1
disk sda 1-1; add sda
gone sda; hdl usb remove 1-1
expect_none "and 1-1"
reset; board v2.4
route_to 1
disk sda 2-1; add sda
hdl usb remove 2-1
expect_link 1 /dev/sda "a USB remove while the disk is still there keeps the link"

echo "7. v2.4, the mux moves to another node"
reset; board v2.4
route_to 1
disk sda 2-1; add sda
gone sda; hdl block remove sda
route_to 3
disk sdb 2-1; add sdb
expect_link 3 /dev/sdb "node 3 is linked after node 1 left"
[ ! -e "$by/node1" ] && ok "and node 1 is gone" || bad "node1 stayed"
reset; board v2.4
route_to 1
disk sda 2-1; add sda
gone sda
route_to 4
disk sdb 2-1; add sdb
expect_link 4 /dev/sdb "node 4 is linked"
[ ! -e "$by/node1" ] && ok "a stale link of the node that left is swept" || bad "node1 stayed"

echo "8. other events do nothing"
reset; board v2.4
route_to 1
disk sda 2-1; disk sda1 2-1
add sda1
expect_none "a partition is not a whole disk"
hdl usb add 2-1:1.0
expect_none "a USB add event makes no link"
SUBSYSTEM=net TPI_ROOT="$TPI_ROOT" ACTION=add MDEV=eth0 sh "$SCRIPT"
expect_none "another subsystem"

echo "9. v2.5, a root port removal is not the helper's business"
reset; board v2.5
disk sda 2-1/2-1.2; add sda
rm -rf "$TPI_ROOT/sys/block/sda"
hdl usb remove 2-1
expect_link 2 /dev/sda "a stale link stays: 2-1 on v2.5 is the hub"
hdl usb remove 2-1.2
expect_none "a hub child port removal sweeps it"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
