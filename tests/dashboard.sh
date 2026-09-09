#!/bin/sh
# Validates dashboards/turingpi-bmc.json, the dashboard published with each
# release.
#
# The failure this guards against is not a typo. It is somebody editing the
# dashboard in a Grafana UI and re-exporting it: Grafana's export bakes in
# whatever datasource uid that instance happens to use and drops __inputs, so
# the file still parses, still imports on the machine it came from, and is
# silently useless to everyone else. No reader of that diff would notice, and
# no import on the author's own Grafana would catch it.
set -eu

DASH="${1:-dashboards/turingpi-bmc.json}"
fail=0

check() {
	if [ "$2" = "0" ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s\n' "$1"
		fail=1
	fi
}

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DASH" 2>/dev/null; then
	check "parses as JSON" 0
else
	check "parses as JSON" 1
	printf '     not JSON, so nothing below could be trusted\n'
	exit 1
fi

if grep -q '"DS_PROMETHEUS"' "$DASH"; then
	check "declares the DS_PROMETHEUS input" 0
else
	check "declares the DS_PROMETHEUS input" 1
	printf '     __inputs is gone: this is a Grafana re-export, and it will bind\n'
	printf '     to whatever datasource the exporting instance happened to use\n'
fi

# Any uid that is not the template variable or the dashboard's own is an
# instance-specific leak.
leaks=$(grep -o '"uid": "[^"]*"' "$DASH" | grep -v 'DS_PROMETHEUS' | grep -v 'turingpi-bmc' || true)
if [ -n "$leaks" ]; then
	check "no hard-coded datasource uid" 1
	printf '%s\n' "$leaks" | sort -u | sed 's/^/     /'
else
	check "no hard-coded datasource uid" 0
fi

# A panel querying a metric that does not exist draws an empty graph, which is
# indistinguishable from a healthy one. A panel with no query at all is worse.
if python3 - "$DASH" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
drawing = [p for p in d['panels'] if p['type'] != 'row']
bare = [p['title'] for p in drawing if not p.get('targets')]
if bare:
    print('     panels with no query:', ', '.join(bare))
    sys.exit(1)
names = sorted(set(re.findall(r'\bbmcd_[a-z0-9_]+', json.dumps(d))))
print('     %d drawing panels over %d bmcd_* metrics' % (len(drawing), len(names)))
PYEOF
then
	check "every drawing panel has a query" 0
else
	check "every drawing panel has a query" 1
fi

exit "$fail"
