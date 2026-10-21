#!/usr/bin/env bash
# Supervise an arm that is already ramping.
#
# 60-run-arm.sh sets an arm up and then supervises it, but an az deploy that reports failure
# while succeeding kills the script and orphans a good run. This attaches to that run instead:
# enforce the cap, catch the death, snapshot, drain.
set -uo pipefail
ARM="${1:?usage: 61-supervise-arm.sh <arm-name> }"
CAP_MINUTES="${CAP_MINUTES:-90}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
WORKER="$WORKER_APP"
DRIVER="$DRIVER_APP"
OUT="$ROOT/docs/results/data/arm-$ARM"
URL="https://$WORKER.azurewebsites.net"
TOKEN=$(tr -d '\n' < "$SECRETS/metrics_token")
addr=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['address'])")
ns=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")
mkdir -p "$OUT"

m()  { curl -sf --max-time 20 -H "Authorization: Bearer $TOKEN" "$URL/$1" 2>/dev/null; }
g()  { awk -v k="$2" '$1==k || index($1,k"{")==1 {print $NF; exit}' <<< "$1"; }

start0=$(g "$(m metrics/runtime)" process_start_time_seconds)
t0=$(date +%s)
echo "supervising arm $ARM, cap ${CAP_MINUTES}m, worker start_time=$start0"

outcome="cap"
while true; do
  sleep 45
  R=$(m metrics/runtime); M=$(m metrics)
  if [ -z "$R" ]; then echo "  unreachable, worker may be dying"; continue; fi
  st=$(g "$R" process_start_time_seconds)
  rss=$(g "$R" process_resident_memory_bytes)
  cached=$(g "$M" temporal_sticky_cache_size)
  if [ -n "$st" ] && [ "$st" != "$start0" ]; then
    echo "outcome=died  worker restarted; last seen ${rss:-?} bytes with ${cached:-?} cached"
    outcome="died"; break
  fi
  el=$(( ($(date +%s) - t0) / 60 ))
  if [ "$el" -ge "$CAP_MINUTES" ]; then
    echo "outcome=survived  reached ${CAP_MINUTES}m cap at ${rss:-?} bytes, ${cached:-?} cached"
    outcome="survived"; break
  fi
done

echo "Snapshotting"
m metrics          > "$OUT/metrics-final.txt"       2>/dev/null
m metrics/runtime  > "$OUT/runtime-final.txt"       2>/dev/null
cp "$ROOT/docs/results/data/arm-samples.tsv" "$OUT/rss-vs-cache.tsv" 2>/dev/null
# Prometheus holds the full series; the snapshot above is only the final instant.
END=$(date +%s); START=$((t0 - 300))
for q in process_resident_memory_bytes temporal_sticky_cache_size \
         temporal_sticky_cache_total_forced_eviction temporal_sticky_cache_hit \
         temporal_sticky_cache_miss dotnet_gc_committed_bytes dotnet_gc_heap_size_bytes \
         dotnet_gc_pause_seconds_total dotnet_gc_allocated_bytes_total \
         process_cpu_seconds_total dotnet_gc_memory_load_bytes; do
  curl -s --max-time 30 --get http://127.0.0.1:9090/api/v1/query_range \
    --data-urlencode "query=$q" --data-urlencode "start=$START" \
    --data-urlencode "end=$END" --data-urlencode "step=30s" -o "$OUT/$q.json" 2>/dev/null
done
echo "  wrote $(ls -1 "$OUT" | wc -l | tr -d ' ') files to $OUT"

echo "Draining"
az webapp stop -g "$RG" -n "$DRIVER" --output none 2>/dev/null || true
tq() { temporal --address "$addr" --namespace "$ns" \
         --tls-cert-path "$SECRETS/client.pem" --tls-key-path "$SECRETS/client.key" "$@"; }
for pass in 1 2 3 4 5 6; do
  tq workflow terminate --query 'ExecutionStatus="Running"' --reason "arm $ARM complete" --yes >/dev/null 2>&1 || true
  sleep 20
  left=$(tq workflow count --query 'ExecutionStatus="Running"' 2>/dev/null | awk -F': *' '/Total/{print $2}' | tr -d ' ')
  echo "  pass $pass: ${left:-unknown} still running"
  [ "${left:-x}" = "0" ] && break
done

echo "arm $ARM done (outcome=$outcome). Summary:"
"$ROOT/deploy/55-arm-summary.sh" "$ARM" 2>/dev/null || true
