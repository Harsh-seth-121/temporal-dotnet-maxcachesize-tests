#!/usr/bin/env bash
# One line per arm: what every worker in the fleet is doing right now.
#
#   ./deploy/67-watch-all.sh          # once
#   watch -n 60 ./deploy/67-watch-all.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
TOK=$(tr -d '\n' < "$(secret metrics_token)")

phase=$(curl -sf --max-time 12 "$DRIVER_URL/" 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['phase'],'started',d['startedTotal'])" 2>/dev/null || echo "unreachable")
printf '%s  driver: %s\n\n' "$(date +%H:%M)" "$phase"
printf '%-16s %-8s %8s %9s %9s %10s %s\n' ARM GC CACHED RSS LOAD EVICTIONS WORKER

python3 - "$STATE" <<'PY' |
import json, sys
s = json.load(open(sys.argv[1]))
for a in sorted(s["arms"], key=lambda a: a.get("order", 0)):
    print(f"{a['arm']}\t{a['gc']}\t{a['worker_app']}")
PY
while IFS=$'\t' read -r arm gc app; do
  url="https://${app}.azurewebsites.net"
  rt=$(curl -sf --max-time 20 -H "Authorization: Bearer $TOK" "$url/metrics/runtime" 2>/dev/null || true)
  m=$(curl -sf --max-time 20 -H "Authorization: Bearer $TOK" "$url/metrics" 2>/dev/null || true)
  if [ -z "$rt" ]; then
    printf '%-16s %-8s %8s %9s %9s %10s %s\n' "$arm" "$gc" "-" "-" "-" "-" "$app unreachable"
    continue
  fi
  rss=$(echo "$rt" | awk '/^process_resident_memory_bytes/{printf "%.2f", $NF/1073741824}')
  load=$(echo "$rt" | awk '/^dotnet_gc_memory_load_bytes/{printf "%.2f", $NF/1073741824}')
  cached=$(echo "$m" | awk '/^temporal_sticky_cache_size/{s+=$NF} END{printf "%d", s+0}')
  ev=$(echo "$m" | awk '/^temporal_sticky_cache_total_forced_eviction/{s+=$NF} END{printf "%d", s+0}')
  printf '%-16s %-8s %8s %8sG %8sG %10s %s\n' "$arm" "$gc" "$cached" "$rss" "${load:--}" "$ev" "$app"
done
