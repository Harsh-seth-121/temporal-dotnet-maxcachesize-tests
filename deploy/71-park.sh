#!/usr/bin/env bash
# Park everything safely before closing the laptop. Idempotent, no arguments, ~4 minutes.
#
#   ./deploy/71-park.sh
#
# An arm cannot survive the laptop going away: Prometheus runs in local Docker so scraping
# stops, while the Azure driver keeps the population heartbeating every 300s once its hold
# ends. At ~8,191 workflows that is ~98,000 Actions an hour, ~$25/hour, on data nobody records.
#
# Deletes nothing. A stopped App Service still bills its plan, ~$3.70/day; only
# ./deploy/99-teardown.sh stops that, and it is not reversible.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
WORKER="$WORKER_APP"
DRIVER="$DRIVER_APP"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

addr=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['address'])")
ns=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")
tq() { temporal --address "$addr" --namespace "$ns" \
         --tls-cert-path "$SECRETS/client.pem" --tls-key-path "$SECRETS/client.key" "$@"; }

# Which arm was in flight, from the state file. A guess here files one arm's series under
# another's name.
inflight=$(python3 - "$STATE" <<'PY' 2>/dev/null || true
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for a in s.get("arms", []):
    if a.get("state") == "launched":
        print(a["arm"]); break
PY
)

say "Stopping the driver first"
# Driver before drain, always. A live driver keeps feeding the queue and the drain below never
# converges. That deadlock cost one arm its whole window.
az webapp stop -g "$RG" -n "$DRIVER" --output none 2>/dev/null || true
echo "  $DRIVER stopped"

say "Draining the namespace"
# Terminate is a batch against eventually-consistent visibility, so one pass misses anything
# mid-start. One pass once left 134 of ~7,200 running, and those keep billing.
drained=no
for pass in 1 2 3 4 5 6; do
  tq workflow terminate --query 'ExecutionStatus="Running"' \
     --reason "parking the harness" --yes >/dev/null 2>&1 || true
  sleep 20
  left=$(tq workflow count --query 'ExecutionStatus="Running"' 2>/dev/null \
         | awk -F': *' '/Total/{print $2}' | tr -d ' ')
  left="${left:-unknown}"
  echo "  pass $pass: $left still running"
  if [ "$left" = "0" ]; then drained=yes; break; fi
done
if [ "$drained" != "yes" ]; then
  echo "  WARNING: namespace still shows $left running after 6 passes." >&2
  echo "  Those keep heartbeating and keep billing. Re-run this script before walking away." >&2
fi

if [ -n "$inflight" ]; then
  say "Saving what the in-flight arm ($inflight) managed to record"
  # Partial data, filed as partial. In the arm's real directory an aborted run later reads as
  # a result.
  OUT="$ROOT/docs/results/data/phase2/arm-${inflight}-aborted"
  mkdir -p "$OUT"
  _end=$(date +%s); _start=$((_end - 9000))
  for _q in process_resident_memory_bytes temporal_sticky_cache_size \
            temporal_sticky_cache_total_forced_eviction temporal_sticky_cache_hit \
            temporal_sticky_cache_miss dotnet_gc_committed_bytes dotnet_gc_heap_size_bytes \
            dotnet_gc_pause_seconds_total dotnet_gc_allocated_bytes_total \
            process_cpu_seconds_total dotnet_gc_memory_load_bytes dotnet_gc_fragmented_bytes \
            dotnet_gc_total_available_bytes process_start_time_seconds \
            temporal_workflow_task_execution_latency_sum \
            temporal_workflow_task_execution_latency_count temporal_worker_task_slots_used; do
    curl -s --max-time 30 --get http://127.0.0.1:9090/api/v1/query_range \
      --data-urlencode "query=${_q}{arm=\"$inflight\"}" --data-urlencode "start=$_start" \
      --data-urlencode "end=$_end" --data-urlencode "step=15s" -o "$OUT/${_q}.json" 2>/dev/null || true
  done
  az webapp log download -g "$RG" -n "$WORKER" --log-file "$OUT/logs.zip" --output none 2>/dev/null || true
  echo "  $(ls -1 "$OUT"/*.json 2>/dev/null | wc -l | tr -d ' ') series into $OUT"
else
  say "No arm was in flight, nothing partial to save"
fi

say "Stopping the worker"
az webapp stop -g "$RG" -n "$WORKER" --output none 2>/dev/null || true
echo "  $WORKER stopped"

say "Updating $STATE"
python3 - "$STATE" "${inflight:-}" <<'PY'
import json,sys,datetime
path, inflight = sys.argv[1], sys.argv[2]
s = json.load(open(path))
if inflight:
    for a in s.get("arms", []):
        if a["arm"] == inflight and a.get("state") == "launched":
            a["state"] = "aborted"
            a["outcome"] = "parked mid-run; series incomplete, do not report"
s.setdefault("infra", {})
s["infra"]["parked"] = True
s["infra"]["worker_app_state"] = "Stopped"
s["infra"]["driver_app_state"] = "Stopped"
s["updated"] = datetime.date.today().isoformat()
json.dump(s, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"  parked{', ' + inflight + ' marked aborted' if inflight else ''}")
PY

say "Parked"
cat <<'MSG'
  Nothing is running, nothing is accruing Actions. Local Prometheus and Grafana are left alone:
  they hold the history and come back with Docker.

  Still billing: the App Service plan, about $3.70/day, because a stopped app keeps its plan.
  ./deploy/99-teardown.sh is the only thing that stops that. It is NOT reversible and a
  reprovision costs about 20 minutes, so it needs an explicit decision.

  Come back with:  /resume-cache-test
MSG
