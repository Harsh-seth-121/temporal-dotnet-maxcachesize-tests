#!/usr/bin/env bash
# Pulls the run's headline numbers out of local Prometheus into a markdown report.
# Read-only: never touches Azure or Temporal Cloud.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1

PROM="${PROM:-http://127.0.0.1:9090}"
OUT="${1:-$ROOT/docs/results/ramp-$(date -u +%Y-%m-%dT%H%M).md}"
mkdir -p "$(dirname "$OUT")"

curl -sf --max-time 10 "$PROM/-/ready" >/dev/null || { echo "Prometheus not reachable at $PROM"; exit 1; }

# The header names the namespace and hardware the report describes. Reading them beats a
# literal that goes stale the first time somebody else runs this.
NS=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")

python3 - "$PROM" "$OUT" "$NS" "$WORKER_SKU" "$LOC" <<'PY'
import json, sys, urllib.parse, urllib.request

prom, out, namespace, sku, location = sys.argv[1:6]

def q(expr):
    url = f"{prom}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)["data"]["result"]

def by_arm(expr):
    d = {}
    for x in q(expr):
        a = x["metric"].get("arm")
        if a:
            d[a] = float(x["value"][1])
    return d

arms = ["10k", "8k", "6k", "ctl"]
cache = {"10k": 10000, "8k": 8000, "6k": 6000, "ctl": 100}

size    = by_arm("temporal_sticky_cache_size")
evict   = by_arm("temporal_sticky_cache_total_forced_eviction")
hit     = by_arm("temporal_sticky_cache_hit")
miss    = by_arm("temporal_sticky_cache_miss")
rss     = by_arm("process_resident_memory_bytes")
slots   = by_arm('temporal_worker_task_slots_available{worker_type="WorkflowWorker"}')
p99     = by_arm("histogram_quantile(0.99, sum by (arm, le) "
                 "(rate(temporal_workflow_task_replay_latency_bucket[10m])))")
# Instantaneous rates. Cumulative counters are diluted by the time the arm spent under its cap
# missing nothing, so they understate steady state.
hrate   = by_arm("sum by (arm) (rate(temporal_sticky_cache_hit[5m]))")
mrate   = by_arm("sum by (arm) (rate(temporal_sticky_cache_miss[5m]))")

rows = []
for a in arms:
    h, m = hit.get(a, 0), miss.get(a, 0)
    ratio = 100 * h / (h + m) if (h + m) else float("nan")
    hr, mr = hrate.get(a, 0), mrate.get(a, 0)
    inst = 100 * mr / (hr + mr) if (hr + mr) > 1e-6 else float("nan")
    rows.append((a, cache[a], size.get(a, 0), evict.get(a, 0), ratio,
                 rss.get(a, 0) / 1e6, p99.get(a, float("nan")), slots.get(a, float("nan")),
                 inst, hr + mr))

L = []
L.append("# Ramp run results\n")
L.append(f"Namespace `{namespace}`, {len(rows)} {sku} App Service arms in {location}, "
         "Temporalio 1.17.0.\n")
L.append("| arm | cache | cached | forced evictions | **miss rate (now)** | hit ratio (cumulative) | RSS MB | wf slots free |")
L.append("|---|---|---|---|---|---|---|---|")
for a, c, s, e, r, m, p, sl, inst, _ in rows:
    L.append(f"| {a} | {c:,} | {s:,.0f} | {e:,.0f} | **{inst:.2f}%** | {r:.1f}% | {m:,.0f} | {sl:,.0f} |")
L.append("\nThe miss rate column is instantaneous (`rate()` over 5m) and is the one to read. "
         "The cumulative hit ratio is diluted by however long the arm spent under its cap "
         "missing nothing, so it flatters an arm that has only recently started thrashing.")

L.append("\n## Validity guards\n")
# Memory-bound: evicting below the configured cap means we measured RAM, not config.
bad = [a for a, c, s, e, *_ in rows if e > 0 and s < c * 0.98 and a != "ctl"]
L.append(f"- Memory-bound arms (evicting below their cap): "
         f"{', '.join(bad) if bad else 'none - good'}")
starved = [a for a, *_ , sl in rows if sl == 0]
L.append(f"- Slot-starved arms (zero workflow slots free): "
         f"{', '.join(starved) if starved else 'none - good'}")
# Scoped to 30m. A restart before the ramp is planned and harmless; one DURING measurement
# empties the cache and invalidates the window.
recent = [f"{x['metric'].get('arm')}={float(x['value'][1]):.0f}"
          for x in q("changes(process_start_time_seconds[30m])") if float(x["value"][1]) > 0]
L.append(f"- Worker restarts in the last 30m (a restart mid-measurement empties the cache "
         f"and invalidates that window): {', '.join(recent) if recent else 'none - good'}")
older = [f"{x['metric'].get('arm')}={float(x['value'][1]):.0f}"
         for x in q("changes(process_start_time_seconds[3h])") if float(x["value"][1]) > 0]
if older:
    L.append(f"  - earlier restarts in 3h (expected if you reset the workers before the run): "
             f"{', '.join(older)}")
# Throughput skew is the effect, not a confound: a thrashing arm replays full history on every
# task and completes fewer per second. Comparing raw throughput across arms would flag every
# successful run, so compare only arms that are hitting cache. Those should match.
healthy = [(a, tot) for a, c, s, e, r, m, p, sl, inst, tot in rows
           if tot > 1e-6 and inst == inst and inst < 50]
if len(healthy) >= 2:
    vals = [t for _, t in healthy]
    skew = 100 * (max(vals) - min(vals)) / max(vals)
    verdict = "good" if skew < 10 else "INVESTIGATE - equally-healthy arms differ in load"
    L.append(f"- Throughput spread among cache-healthy arms "
             f"({', '.join(a for a, _ in healthy)}): {skew:.1f}% - {verdict}")
else:
    L.append("- Throughput spread: not comparable (fewer than two arms are cache-healthy). "
             "Offered load evenness is guaranteed by the driver starting all arms in lockstep; "
             "verify independently with a per-task-queue open-workflow count if in doubt.")
L.append("  - Note: arms at a high miss rate legitimately process FEWER tasks per second, "
         "because each miss costs a full history replay. That difference is the effect being "
         "measured, not evidence of uneven input.")

L.append("\n## Memory\n")
for a, c, s, e, r, m, p, sl, inst, _ in rows:
    if s > 0:
        L.append(f"- `{a}` {m:,.0f} MB RSS holding {s:,.0f} cached workflows "
                 f"= {m*1e6/s/1024:,.0f} KB each (includes baseline process footprint)")
L.append("\nThe marginal cost per cached workflow is the SLOPE of RSS against cached workflows "
         "across the ramp, not the ratio at a point. Read it off the Grafana RSS panel.\n")

open(out, "w").write("\n".join(L) + "\n")
print(f"wrote {out}")
for line in L[3:9]:
    print("  " + line)
PY
