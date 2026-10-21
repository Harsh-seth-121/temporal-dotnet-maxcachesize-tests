#!/usr/bin/env bash
# Backfill an arm's worker-recorded samples into local Prometheus, so Grafana shows the whole
# arm instead of the minutes the laptop was awake.
#
#   ./deploy/63-backfill-prometheus.sh <arm>        e.g. c10000, c8000-nolimit
#
# The worker samples itself to /home/LogFiles every 30s; Prometheus in local Docker misses that
# stretch. This converts the worker's record to OpenMetrics and has promtool write TSDB blocks
# into the Prometheus data volume. Same dashboards, same queries, no gap.
#
# Safe to re-run: promtool writes new blocks, and Prometheus drops duplicate samples for a
# series at the same millisecond on read.
set -euo pipefail

ARM="${1:?usage: 63-backfill-prometheus.sh <arm>   e.g. c10000}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
WORKER="$WORKER_APP"
PROM="${PREFIX}-prom"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

say "Fetching the worker's samples"
# Prefer what 62-collect-arm.sh downloaded; hit the network only if there is nothing.
# Match the sampler's naming, arm-<arm>-<process start>.tsv, NOT *.tsv. The arm directory also
# holds phase 1's rss-vs-cache.tsv, a different format: through this converter it produced one
# series per row and promtool rejected the file with 'expected metric name after TYPE, got "1"'.
mapfile -t tsvs < <(find "$ROOT/docs/results/data/phase2/arm-${ARM}" -name "arm-${ARM}-*.tsv" 2>/dev/null | sort)
if [ "${#tsvs[@]}" -eq 0 ]; then
  az webapp log download -g "$RG" -n "$WORKER" --log-file "$TMP/logs.zip" --output none
  unzip -oq "$TMP/logs.zip" -d "$TMP/logs"
  mapfile -t tsvs < <(find "$TMP/logs" -name "arm-${ARM}-*.tsv" | sort)
fi
[ "${#tsvs[@]}" -eq 0 ] && { echo "FATAL: no samples for arm ${ARM}" >&2; exit 1; }
echo "  ${#tsvs[@]} instance file(s), $(cat "${tsvs[@]}" | grep -cv '^#') rows"
cat "${tsvs[@]}" > "$TMP/all.tsv"

say "Converting to OpenMetrics"
"$ROOT/deploy/lib-tsv-to-openmetrics.py" "$TMP/all.tsv" "$TMP/backfill.om" \
  --instance "${WORKER}.azurewebsites.net:443"

say "Writing TSDB blocks into $PROM"
docker ps --format '{{.Names}}' | grep -qx "$PROM" || { echo "FATAL: $PROM is not running. ./deploy/70-resume.sh" >&2; exit 1; }
docker cp "$TMP/backfill.om" "$PROM:/tmp/backfill.om"
# --max-block-duration keeps blocks small enough that Prometheus loads them without waiting
# for its next compaction cycle.
docker exec "$PROM" promtool tsdb create-blocks-from openmetrics \
  --max-block-duration=2h /tmp/backfill.om /prometheus | tail -3

say "Restarting Prometheus so it picks the blocks up"
# Prometheus scans its data directory at startup. Without this the blocks sit unread until the
# next compaction, while someone stares at an empty graph.
docker restart "$PROM" >/dev/null
for i in $(seq 1 30); do
  curl -sf --max-time 3 http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && { echo "  ready"; break; }
  sleep 2
done

say "Check it landed"
lo=$(awk '!/^#/{print $NF}' "$TMP/backfill.om" | sort -n | head -1)
hi=$(awk '!/^#/{print $NF}' "$TMP/backfill.om" | sort -n | tail -1)
_hhmm() { python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(float(sys.argv[1]))).strftime('%H:%M'))" "$1"; }
echo "  samples span $(_hhmm "$lo") to $(_hhmm "$hi")"
# /-/ready returns before the new blocks are queryable, so one check right after the restart
# reports zero for a backfill that landed. Arm 2 hit this.
n=0
for _try in 1 2 3 4 5; do
n=$(curl -s --get http://127.0.0.1:9090/api/v1/query_range \
      --data-urlencode "query=process_resident_memory_bytes{arm=\"$ARM\"}" \
      --data-urlencode "start=$lo" --data-urlencode "end=$hi" --data-urlencode "step=30s" \
    | python3 -c "import json,sys;r=json.load(sys.stdin)['data']['result'];print(sum(len(s['values']) for s in r))" 2>/dev/null || echo 0)
  [ "${n:-0}" != "0" ] && break
  sleep 5
done
echo "  Prometheus now returns $n RSS samples over that window"
[ "$n" = "0" ] && echo "  WARNING: nothing came back. Check 'docker logs $PROM' for a block load error." >&2
echo
echo "  Grafana: http://127.0.0.1:3000/d/temporal-core-sdk/02415ea  (set the range to cover the arm)"
