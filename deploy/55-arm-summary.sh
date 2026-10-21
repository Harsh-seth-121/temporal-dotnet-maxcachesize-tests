#!/usr/bin/env bash
# Summarises one arm from its captured artifacts. Read-only, touches nothing live.
#   ./deploy/55-arm-summary.sh c10000
set -uo pipefail
ARM="${1:?usage: 55-arm-summary.sh <arm>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$ROOT/docs/results/data/arm-${ARM}"
[[ -d "$D" ]] || { echo "no artifacts at $D"; exit 1; }

python3 - "$D" "$ARM" << 'PY'
import sys, re, pathlib
d, arm = pathlib.Path(sys.argv[1]), sys.argv[2]

def series(fn, key):
    """Sum every labelled series whose name is exactly `key`."""
    f = d/fn
    if not f.exists(): return None
    tot, seen = 0.0, False
    for line in f.read_text().splitlines():
        if line.startswith("#"): continue
        m = re.match(rf"^{re.escape(key)}(\{{[^}}]*\}})?\s+(\S+)$", line)
        if m:
            try: tot += float(m.group(2)); seen = True
            except ValueError: pass
    return tot if seen else None

def fmt(v, unit=""):
    return "n/a" if v is None else (f"{v:,.2f}{unit}" if unit else f"{v:,.0f}")

M, R = "final-metrics.txt", "final-runtime.txt"
cached  = series(M, "temporal_sticky_cache_size")
evict   = series(M, "temporal_sticky_cache_total_forced_eviction")
hit     = series(M, "temporal_sticky_cache_hit")
miss    = series(M, "temporal_sticky_cache_miss")
rss     = series(R, "process_resident_memory_bytes")
cpu     = series(R, "process_cpu_seconds_total")
cpusys  = series(R, "process_cpu_system_seconds_total")
cores   = series(R, "process_available_cores")
pause   = series(R, "dotnet_gc_pause_seconds_total")
alloc   = series(R, "dotnet_gc_allocated_bytes_total")
ceiling = series(R, "dotnet_gc_total_available_bytes")
commit  = series(R, "dotnet_gc_committed_bytes")

print(f"\n  ARM {arm}")
print(f"  {'cached workflows':<28} {fmt(cached)}")
print(f"  {'forced evictions':<28} {fmt(evict)}")
if hit is not None and miss is not None and hit+miss > 0:
    print(f"  {'cache hit ratio':<28} {100*hit/(hit+miss):,.2f}%")
if rss:     print(f"  {'peak RSS':<28} {rss/1073741824:,.2f} GiB")
if ceiling: print(f"  {'GC ceiling':<28} {ceiling/1073741824:,.2f} GiB")
if commit:  print(f"  {'GC committed':<28} {commit/1073741824:,.2f} GiB")
if rss and cached: print(f"  {'bytes per cached workflow':<28} {rss/cached/1024:,.0f} KB (incl. baseline)")
if cpu:     print(f"  {'CPU seconds':<28} {cpu:,.0f}" + (f"  ({cpusys/cpu*100:,.0f}% system)" if cpusys and cpu else ""))
if cores:   print(f"  {'cores available':<28} {cores:,.0f}")
if pause:   print(f"  {'GC pause seconds':<28} {pause:,.2f}")
if alloc:   print(f"  {'total allocated':<28} {alloc/1073741824:,.1f} GiB")

# The exit code is the authoritative cause of death.
ec = d/"exit-codes.log"
print()
MEANING = {"137": "SIGKILL - kernel OOM kill, no managed exception and no dump",
           "134": "SIGABRT - unhandled OutOfMemoryException, CLR fatal path",
           "143": "SIGTERM - graceful stop: platform recycle, deploy, or setting change"}
if ec.exists():
    lines = [l for l in ec.read_text().splitlines() if l.strip()]
    exits = [l for l in lines if "WORKER-EXIT" in l]
    starts = [l for l in lines if "WORKER-START" in l]
    if not exits:
        print(f"  {len(starts)} start(s) logged, no exit: the worker is still running")
    for line in exits[-3:]:
        m = re.search(r"code=(\d+)", line)
        code = m.group(1) if m else "?"
        when = line.split()[0]
        print(f"  {when}  exit {code}: {MEANING.get(code, 'uncommon code, check the container log')}")
    # A start with no matching exit after the last exit means it came back up.
    if starts and exits and starts[-1] > exits[-1]:
        print("  restarted afterwards, so the metrics above are from before the death")
else:
    print("  no exit-code log. Arm A predates the wrapper; attribute it from the container log")
PY
