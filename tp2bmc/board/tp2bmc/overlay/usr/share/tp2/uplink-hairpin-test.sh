#!/bin/sh
# Detect node→WAN traffic hairpinning through eth0 (100M CPU port) vs ASIC switch.
#
# Usage (on BMC):
#   sh /usr/share/tp2/uplink-hairpin-test.sh [gateway-ip]
#
# While this script waits, on a powered node run:
#   iperf3 -c <gateway-ip> -t10
#   # optional: iperf3 -c <gateway-ip> -t10 -P 4
#
# Pass: eth0 byte delta stays modest; node iperf ~900+ Mbit/s (not ~88 Mbit/s).
# Fail: eth0 grows ~100MB per 10s iperf → bond+br0 missing net-dsa/0003 fixup.

set -u

GW=${1:-}
WAIT=${UPLINK_TEST_WAIT:-45}
RESULT=/var/run/tp2-uplink-test-eth0-delta

log() {
	echo "uplink-hairpin-test: $*" >&2
}

# The conduit is eth0 on current images, but sun8i-emac enumerates as end0
# under some kernel/DT combinations. Probe, and let the caller override.
conduit_netdev() {
	for c in ${UPLINK_CONDUIT:-} eth0 end0; do
		[ -n "$c" ] || continue
		[ -r "/sys/class/net/$c/statistics/rx_bytes" ] || continue
		printf '%s\n' "$c"
		return 0
	done
	return 1
}

if [ ! -d /sys/class/net/bond0 ]; then
	log "skip — bond0 not configured"
	exit 0
fi

if ! grep -q "802.3ad" /proc/net/bonding/bond0 2>/dev/null; then
	log "skip — bond0 is not 802.3ad"
	exit 0
fi

if [ -z "$GW" ]; then
	GW=$(ip -4 route show dev br0 default 2>/dev/null | awk '{print $3; exit}')
fi
[ -n "$GW" ] || GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')

if [ -z "$GW" ]; then
	log "error: no gateway — pass IP as first argument"
	exit 1
fi

CONDUIT=$(conduit_netdev) || {
	log "error: no DSA conduit netdev (tried eth0, end0; set UPLINK_CONDUIT)"
	exit 1
}
STATS=/sys/class/net/$CONDUIT/statistics

RX0=$(cat "$STATS/rx_bytes")
TX0=$(cat "$STATS/tx_bytes")

log "conduit=$CONDUIT gateway=$GW — on a powered node run: iperf3 -c $GW -t10"
log "waiting ${WAIT}s for traffic..."

sleep "$WAIT"

RX1=$(cat "$STATS/rx_bytes")
TX1=$(cat "$STATS/tx_bytes")
DRX=$((RX1 - RX0))
DTX=$((TX1 - TX0))
DELTA=$((DRX + DTX))

echo "$DELTA" >"$RESULT"

log "$CONDUIT delta RX=$DRX TX=$DTX total=$DELTA bytes"

# ~88 Mbit/s for 10s ≈ 110 MiB one direction; hairpin often shows ~100MB+ each way
THRESH=${UPLINK_ETH0_DELTA_MAX:-67108864}

if [ "$DELTA" -gt "$THRESH" ]; then
	log "FAIL — $CONDUIT moved ${DELTA} bytes (>${THRESH}): node WAN likely via CPU (100M)"
	log "check kernel includes net-dsa/0003 and dmesg for 'LAG bridge uplink fixup'"
	exit 1
fi

if dmesg 2>/dev/null | grep -q "LAG bridge uplink fixup"; then
	log "PASS — $CONDUIT quiet; driver reported LAG bridge uplink fixup"
else
	log "PASS — $CONDUIT quiet (no large hairpin); fixup message not in dmesg (older kernel?)"
fi

exit 0
