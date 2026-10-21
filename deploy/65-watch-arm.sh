#!/usr/bin/env bash
# Watch one arm. Least-squares slope over the whole run, not a pairwise delta: RSS moves in
# GC-sized steps, so consecutive samples read 89 to 1,007 KB per workflow on the same ramp.
# 35s, not 20: GC pauses under eviction churn block the HTTP listener past 20s, and a short
# timeout records a gap for a worker that is alive and slow.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
TOKEN=$(tr -d '\n' < "$(secret metrics_token)")
URL="$WORKER_URL"
HIST="${HIST:-$ROOT/docs/results/data/arm-samples.tsv}"
mkdir -p "$(dirname "$HIST")"
: > "$HIST"
BASE_START=""
i=0
while true; do
  i=$((i+1))
  M=$(curl -sf --max-time 35 -H "Authorization: Bearer $TOKEN" "$URL/metrics" 2>/dev/null)
  R=$(curl -sf --max-time 35 -H "Authorization: Bearer $TOKEN" "$URL/metrics/runtime" 2>/dev/null)
  if [ -z "$R" ]; then
    echo "UNREACHABLE sample=$i (worker may be dying or restarting)"
    sleep 45; continue
  fi
  g() { awk -v k="$1" '$1==k || index($1,k"{")==1 {print $NF; exit}' <<< "$2"; }
  cached=$(g temporal_sticky_cache_size "$M")
  evict=$(g temporal_sticky_cache_total_forced_eviction "$M")
  rss=$(g process_resident_memory_bytes "$R")
  st=$(g process_start_time_seconds "$R")
  committed=$(g dotnet_gc_committed_bytes "$R")
  # Baseline only once the cache is filling. 60-run-arm.sh restarts the worker to clear the
  # cache, and a baseline taken before that reads the planned restart as a death.
  if [ -z "$BASE_START" ]; then
    if [ -n "$cached" ] && [ "${cached%.*}" -gt 50 ] 2>/dev/null; then
      BASE_START="$st"
      echo "baselined at start_time=$st with $cached cached; restarts after this point are real"
    else
      sleep 45; continue
    fi
  fi
  # Classify the restart rather than calling every one a death. The planned cache-clearing
  # restart happens at low memory; an OOM happens near the ceiling. Treating them alike ended
  # the watch twice on a restart the runner had just performed.
  if [ -n "$st" ] && [ "$st" != "$BASE_START" ]; then
    hot=$(awk -v r="${LAST_RSS:-0}" 'BEGIN{print (r > 0.6*6.5*1073741824) ? "yes" : "no"}')
    if [ "$hot" = "yes" ]; then
      echo "WORKER DIED at $(awk -v r="$LAST_RSS" 'BEGIN{printf "%.2f", r/1073741824}') GiB with ${LAST_CACHED:-?} cached. Likely OOM; confirm with the exit code"
      exit 0
    fi
    echo "planned restart (was at $(awk -v r="${LAST_RSS:-0}" 'BEGIN{printf "%.2f", r/1073741824}') GiB, well below the ceiling); re-baselining"
    BASE_START="$st"
    : > "$HIST"          # cache emptied, so old samples would corrupt the fit
    sleep 45; continue
  fi
  LAST_RSS="$rss"; LAST_CACHED="$cached"
  if [ -n "$cached" ] && [ -n "$rss" ]; then
    printf '%s\t%s\t%s\t%s\n' "$cached" "$rss" "$(date +%s)" "${evict:-0}" >> "$HIST"
  fi
  # Report every 4th sample so the stream stays readable.
  if [ $((i % 4)) -eq 0 ]; then
    python3 - "$HIST" "$cached" "$rss" "${evict:-0}" "${committed:-0}" << 'PY'
import sys
hist, cached, rss, evict, committed = sys.argv[1:6]
pts=[]
for line in open(hist):
    f=line.split()
    if len(f) >= 2 and float(f[0]) > 300:
        pts.append((float(f[0]), float(f[1]),
                    float(f[2]) if len(f) > 2 else None,
                    float(f[3]) if len(f) > 3 else 0.0))
msg=f"cached={float(cached):,.0f} rss={float(rss)/2**30:.2f}GiB evict={float(evict):,.0f} committed={float(committed)/2**30:.2f}GiB"

def fit(xs, ys):
    n=len(xs); sx=sum(xs); sy=sum(ys); sxx=sum(x*x for x in xs); sxy=sum(x*y for x,y in zip(xs,ys))
    d=n*sxx-sx*sx
    return (None,None) if not d else ((n*sxy-sx*sy)/d, (sy-((n*sxy-sx*sy)/d)*sx)/n)

# Once the population stops growing, every further byte is history accrual, not new workflows.
# That rate against the remaining headroom is time-to-OOM.
CEIL = 6.5*2**30
# Gate on eviction GROWTH, not absolute count. A few evictions from startup drain remnants are
# not eviction pressure, and treating them as such once suppressed the accrual fit for a whole
# run, which is the measurement the hold exists to produce.
ev_hist = [p[3] for p in pts if len(p) > 3]
ev_growth = (ev_hist[-1] - ev_hist[-min(10, len(ev_hist))]) if len(ev_hist) >= 2 else 0.0
if len(pts) < 10:
    msg += f" | ramping ({len(pts)}/10 samples before a fit)"
elif ev_growth >= 50:
    msg += f" | EVICTING (+{ev_growth:,.0f} recently): population not constant, accrual fit suspended"
else:
    top = max(p[0] for p in pts)
    hold = [p for p in pts if p[0] >= top*0.995 and len(p) > 2]
    if len(hold) >= 8:
        t0 = hold[0][2]
        sl, it = fit([p[2]-t0 for p in hold], [p[1] for p in hold])
        if sl and sl > 0:
            per_hr = sl*3600
            head = CEIL - float(rss)
            msg += f" | HOLD accrual {per_hr/2**20:,.0f}MB/hr"
            msg += f", headroom {head/2**30:.2f}GiB, OOM in {head/per_hr:,.1f}h"
            # Deceleration check: a curving fit makes the linear projection pessimistic.
            if len(hold) >= 16:
                h2 = hold[len(hold)//2:]
                sl2, _ = fit([p[2]-t0 for p in h2], [p[1] for p in h2])
                if sl2 is not None and per_hr:
                    msg += f" (recent half {sl2*3600/2**20:,.0f}MB/hr)"
        elif sl is not None:
            msg += " | HOLD accrual flat: memory is not growing at constant population"

if len(pts) >= 8:
    n=len(pts); sx=sum(p[0] for p in pts); sy=sum(p[1] for p in pts)
    sxx=sum(p[0]**2 for p in pts); sxy=sum(p[0]*p[1] for p in pts)
    d=n*sxx-sx*sx
    if d:
        sl=(n*sxy-sx*sy)/d; it=(sy-sl*sx)/n
        if sl>0:
            msg+=f" | fit {sl/1024:,.0f}KB/wf, ceiling at {(6.5*2**30-it)/sl:,.0f} cached"
print(msg)
PY
  fi
  sleep 45
done
