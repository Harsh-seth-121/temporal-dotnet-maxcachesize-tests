#!/usr/bin/env python3
"""Merge every arm's captured series into one JSON the reports read.

Keeps analysis out of the reports: everything derived lands here, so a number in the HTML
traces to a file in docs/results/data/ rather than being recomputed by hand.
"""
import datetime, json, pathlib, sys, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "docs/results/data"
# Fallback only. Phase 1 pinned DOTNET_GCHeapHardLimit=0x1A0000000 and never exported
# dotnet_gc_total_available_bytes, so those arms have no series and must keep reading 6.5 GiB.
# Phase 2's nolimit arms size to the host, where this constant is wrong; they take their
# ceiling from the series (see ceiling()).
CEILING = 6.5 * 1024**3


def series(arm_dir, metric):
    f = arm_dir / f"{metric}.json"
    if not f.exists():
        return []
    try:
        res = json.loads(f.read_text())["data"]["result"]
    except Exception:
        return []
    out = []
    for s in res:
        out += [(int(float(t)), float(v)) for t, v in s.get("values", [])]
    return sorted(set(out))


def final(arm_dir, metric, cut=None, lo=None):
    s = [p for p in series(arm_dir, metric)
         if (lo is None or p[0] >= lo) and (cut is None or p[0] < cut)]
    return s[-1][1] if s else None


def peak(arm_dir, metric, cut=None, lo=None):
    s = [p for p in series(arm_dir, metric)
         if (lo is None or p[0] >= lo) and (cut is None or p[0] < cut)]
    return max(v for _, v in s) if s else None


def ceiling(arm_dir, cut=None, lo=None):
    """The GC's own view of how much memory it may use, in bytes.

    dotnet_gc_total_available_bytes is what the runtime decided at startup: the hard limit when
    set, the host-derived budget when not. A nolimit arm's ceiling is a property of the App
    Service plan, not of our configuration, so read it rather than assume.

    MAXIMUM over the arm window, not the last sample. The value is constant for a process's
    life (122/122 identical samples in the one exported arm), so max and last agree on clean
    data, but max cannot be dragged down by a final sample in a scrape gap. Same failure that
    forced peak() on the eviction counter.

    No series, as in every phase 1 arm, falls back to the configured hard limit.
    """
    return peak(arm_dir, "dotnet_gc_total_available_bytes", cut, lo) or CEILING


MEANING = {"137": "kernel OOM kill (SIGKILL)",
           "134": "unhandled OutOfMemoryException (SIGABRT)",
           "143": "graceful stop (SIGTERM)"}


def exits(arm_dir):
    """Every exit in the log, oldest first, as (unix seconds, record).

    The worker's log is cumulative across every arm the app has run, so the caller must scope
    these to a window. Matching on arm name alone once attributed phase 1's c8000 kill, dated
    2026-10-19T20:07:23Z, to a phase 2 arm that ran a day later and did not die.
    """
    f = arm_dir / "exit-codes.log"
    if not f.exists():
        return []
    out = []
    for line in f.read_text().splitlines():
        m = re.search(r"code=(\d+)", line)
        if not m:
            continue
        try:
            when = datetime.datetime.strptime(line.split()[0], "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc).timestamp()
        except (ValueError, IndexError):
            continue
        out.append((when, {"code": m.group(1),
                           "meaning": MEANING.get(m.group(1), "uncommon"),
                           "at": line.split()[0]}))
    return sorted(out)


def exit_info(arm_dir, since=None, until=None):
    """The exit belonging to one instance's window, or None.

    Bounded at BOTH ends. Bounding only at the start reported a dead process's exit code beside
    a live replacement's series: five of six phase 2 arms were killed mid-arm and restarted
    within 35s, so the replacement's window began inside the 120s of slack below.
    """
    for when, rec in exits(arm_dir):
        # 120s of slack. The start wrapper writes the log line as the process dies, which can
        # land just before the window's first metrics sample.
        if since is not None and when < since - 120:
            continue
        if until is not None and when > until:
            continue
        return rec
    return None


def fit(xs, ys):
    n = len(xs)
    if n < 3:
        return None, None
    sx, sy = sum(xs), sum(ys)
    d = n * sum(x * x for x in xs) - sx * sx
    if not d:
        return None, None
    sl = (n * sum(x * y for x, y in zip(xs, ys)) - sx * sy) / d
    return sl, (sy - sl * sx) / n


def instances(arm_dir):
    """Every worker process in the export, oldest first.

    Each entry is {start, lo, hi, next_lo, samples}: process_start_time_seconds, its own first
    and last sample, and where the next process begins. An export spans several processes:
    60-run-arm.sh restarts the worker to clear the cache, and a worker killed mid-arm is
    restarted by the platform within seconds.
    """
    st = series(arm_dir, "process_start_time_seconds")
    if not st:
        return []
    groups = {}
    for t, v in st:
        groups.setdefault(v, []).append(t)
    ordered = sorted(groups.items(), key=lambda kv: min(kv[1]))
    out = []
    for i, (v, ts) in enumerate(ordered):
        nxt = min(ordered[i + 1][1]) if i + 1 < len(ordered) else None
        out.append({"start": v, "lo": min(ts), "hi": max(ts), "next_lo": nxt,
                    "samples": len(ts)})
    return out


def arm_window(arm_dir):
    """The time range the arm ran on, as (start, end, instance, all instances).

    Anchored on the exit log, not on which process produced the most samples.

    Picking the biggest process works only for the planned restart at the head of an arm. When
    a worker is OOM-killed mid-arm the platform restarts it, the replacement runs to the end of
    the export and becomes the biggest, and the measurements leading up to the kill are thrown
    away. Five of six phase 2 arms were reported that way: a replacement's peak memory,
    evictions and CPU, with the dead process's exit 137 beside them.

    The kill defines the arm, so find it first. An exit landing after one instance's last
    sample and before the next instance starts belongs to that instance, and that instance is
    the arm. No exit means nothing was killed, so the arm is the longest-lived instance.
    """
    inst = instances(arm_dir)
    if not inst:
        return None, None, None, []
    ex = exits(arm_dir)
    for i in inst:
        end = i["next_lo"] if i["next_lo"] is not None else float("inf")
        # Same 120s of slack as exit_info, for a log line written as the process dies.
        if any(i["lo"] - 120 <= when <= end for when, _ in ex):
            return i["lo"], i["next_lo"], i, inst
    chosen = max(inst, key=lambda i: i["samples"])
    return chosen["lo"], chosen["next_lo"], chosen, inst


def arm(arm_dir):
    name = arm_dir.name.replace("arm-", "")
    phase = 2 if arm_dir.parent.name == "phase2" else 1
    # Phase 2 names carry a suffix, "c10000-nolimit". Stripping non-digits survives it because
    # the suffix is pure letters. A digit in a suffix would fuse into the cache size, so keep
    # suffixes alphabetic.
    cache = int(re.sub(r"\D", "", name) or 0)
    retained_kb = 520 if phase == 2 else 640
    lo, cut, chosen, inst = arm_window(arm_dir)

    # A surviving arm leaves the worker running and idle. Running the window to the last
    # sample taken made arm 2 measure 1,018 minutes of wall for a two-hour arm, diluting GC
    # pause to 0.45% and CPU to 4%. End the window where work stops: the workflow task counter
    # climbs while the worker handles tasks and goes flat once the population is drained.
    # Surviving arms only. A killed arm's window already ends where the replacement starts, and
    # trimming an idle tail again would cut real samples from the approach to the kill.
    work = series(arm_dir, "temporal_workflow_task_execution_latency_count") if cut is None else []
    if work:
        totals, last_active = {}, None
        for t, v in work:
            totals[t] = totals.get(t, 0) + v
        prev = None
        for t in sorted(totals):
            if prev is not None and totals[t] > prev:
                last_active = t
            prev = totals[t]
        if last_active is not None:
            # Two minutes of grace so a busy arm's final samples are not clipped.
            idle_cut = last_active + 120
            cut = idle_cut if cut is None else min(cut, idle_cut)
    def win(pts):
        return [p for p in pts if (lo is None or p[0] >= lo) and (cut is None or p[0] < cut)]
    rss = win(series(arm_dir, "process_resident_memory_bytes"))
    cac = dict(win(series(arm_dir, "temporal_sticky_cache_size")))
    if not rss:
        return None

    paired = [(cac[t], v) for t, v in rss if t in cac and cac[t] > 300]
    top = max((c for c, _ in paired), default=0)
    ramp = [(c, v) for c, v in paired if c < top * 0.995] or paired
    slope, base = fit([c for c, _ in ramp], [v for _, v in ramp])

    # Bounded by this instance's window. `cut` is where the NEXT process starts, so an exit
    # after it belongs to a later process.
    ex = exit_info(arm_dir, lo, cut)
    died = bool(ex and ex["code"] in ("137", "134"))
    hit, miss = final(arm_dir, "temporal_sticky_cache_hit", cut, lo), final(arm_dir, "temporal_sticky_cache_miss", cut, lo)
    cpu, pause = final(arm_dir, "process_cpu_seconds_total", cut, lo), final(arm_dir, "dotnet_gc_pause_seconds_total", cut, lo)
    wall = (rss[-1][0] - rss[0][0]) if len(rss) > 1 else 0

    return {
        "arm": name, "cache_size": cache, "died": died, "exit": ex,
        # How many worker processes the export covers, and which one these numbers describe.
        # More than one means a restart: planned before the arm, or a kill during it. A row
        # describes ONE process, not the whole arm, so check these before comparing arms.
        "instances": len(inst),
        "instance_index": (inst.index(chosen) + 1) if chosen else None,
        "instance_start": chosen["start"] if chosen else None,
        "wall_seconds": wall,
        "peak_cached": top,
        "final_cached": cac[rss[-1][0]] if rss[-1][0] in cac else None,
        "peak_rss_gib": (peak(arm_dir, "process_resident_memory_bytes", cut, lo) or 0) / 1024**3,
        "final_rss_gib": rss[-1][1] / 1024**3,
"phase": phase,
        "retained_kb": retained_kb,
        "peak_committed_gib": (peak(arm_dir, "dotnet_gc_committed_bytes", cut, lo) or 0) / 1024**3,
        "peak_memory_load_gib": (peak(arm_dir, "dotnet_gc_memory_load_bytes", cut, lo) or 0) / 1024**3,
        "peak_fragmented_gib": (peak(arm_dir, "dotnet_gc_fragmented_bytes", cut, lo) or 0) / 1024**3,
        "ceiling_gib": ceiling(arm_dir, cut, lo) / 1024**3,
        # Monotonic counter, so peak not final. A final sample in a scrape gap reads 0, which
        # reported arm A as having no evictions when it had 2.
        "forced_evictions": peak(arm_dir, "temporal_sticky_cache_total_forced_eviction", cut, lo) or 0,
        "hit": hit, "miss": miss,
        "hit_ratio": (hit / (hit + miss) * 100) if hit is not None and miss is not None and (hit + miss) else None,
        "cpu_seconds": cpu,
        "cpu_utilisation_pct": (cpu / wall / 2 * 100) if cpu and wall else None,
        "gc_pause_seconds": pause,
        "gc_pause_pct": (pause / wall * 100) if pause and wall else None,
        "allocated_gib": (final(arm_dir, "dotnet_gc_allocated_bytes_total", cut, lo) or 0) / 1024**3,
        "slope_kb_per_wf": slope / 1024 if slope else None,
        "baseline_gib": base / 1024**3 if base else None,
        "rss_series": [[t, round(v / 1024**3, 3)] for t, v in rss],
        "cached_series": [[t, c] for t, c in sorted(cac.items())],
    }


def write_summary(arms):
    """The pasteable version. Nothing should open a 47 KB JSON to learn an arm's outcome."""
    rows = ["# Arm results", "",
            "Generated by `./deploy/57-report-data.py --summary`. Do not hand-edit.",
            "Full timeseries, for charts, stay in `data/report-data.json`.", "",
            "| phase | retained | arm | cache | outcome | exit | peak cached | peak RSS | peak mem load | "
            "evictions | hit % | GC pause | CPU |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for x in arms:
        ex = x["exit"]["code"] if x["exit"] else "-"
        hr = f"{x['hit_ratio']:.1f}" if x["hit_ratio"] else "-"
        gp = f"{x['gc_pause_pct']:.1f}%" if x["gc_pause_pct"] else "-"
        cu = f"{x['cpu_utilisation_pct']:.0f}%" if x["cpu_utilisation_pct"] else "-"
        rows.append(
            f"| p{x.get('phase', 1)} | {x.get('retained_kb', 640)} KB | {x['arm']} | {x['cache_size']:,} | {'died' if x['died'] else 'no terminal outcome'} "
            f"| {ex} | {x['peak_cached']:,.0f} | {x['peak_rss_gib']:.2f} GiB "
            f"| {x.get('peak_memory_load_gib', 0):.2f} / {x['ceiling_gib']:.2f} GiB "
            f"| {x['forced_evictions']:,.0f} | {hr} | {gp} | {cu} |")
    out = DATA.parent / "report-summary.md"
    out.write_text("\n".join(rows) + "\n")
    return out


def main():
    want_summary = "--summary" in sys.argv
    # "-aborted" directories are partial series from 71-park.sh. They carry the full metric
    # set, so only the name distinguishes them and the suffix-tolerant cache_size parse would
    # report one as a finished arm.
    # Phase 2 reuses phase 1's arm names (c10000, c8000, c6000) with the payload changed from
    # 640 KB to 520 KB, so its data lives in data/phase2/ and the two read as separate arms.
    # Without the split, collecting a phase 2 arm overwrote its phase 1 namesake and the
    # summary reported a hybrid: today's peak cached beside the older run's exit code.
    def usable(d):
        # "-prev-<stamp>" is a superseded run kept as evidence. "-aborted" is a partial from
        # 71-park.sh. Neither is a result, and both would appear as extra same-named arms.
        if "-prev-" in d.name:
            return False
        return (d.is_dir() and not d.name.endswith("-aborted")
                and (d / "process_resident_memory_bytes.json").exists())
    dirs = sorted(d for d in DATA.glob("arm-*") if usable(d))
    dirs += sorted(d for d in (DATA / "phase2").glob("arm-*") if usable(d))
    arms = [a for a in (arm(d) for d in dirs) if a]
    if not arms:
        print("no arm data yet", file=sys.stderr)
        return 1
    # For callers wanting a single ceiling; each arm's own "ceiling_gib" is authoritative.
    # Phase 2 mixes limited and nolimit arms, so one number for all of them holds only when they
    # agree. When they do not, fall back to the hard limit.
    ceilings = {a["ceiling_gib"] for a in arms}
    out = {"ceiling_gib": ceilings.pop() if len(ceilings) == 1 else CEILING / 1024**3,
           "arms": arms}
    p = DATA / "report-data.json"
    p.write_text(json.dumps(out, indent=1))
    print(f"  {len(arms)} arm(s) -> {p.relative_to(ROOT)}  ({p.stat().st_size/1024:,.0f} KB)")
    for a in arms:
        # Not "survived". A cut-short arm has no terminal outcome, and phase 1 printed
        # "survived" for one stopped at 48 of 90 minutes.
        v = "died" if a["died"] else "no terminal outcome"
        print(f"    p{a.get('phase', 1)} {a['arm']:<8} {a.get('retained_kb', 640)}KB cache {a['cache_size']:>6,}  {v:<9}"
              f" peak {a['peak_cached']:>6,} cached  {a['peak_rss_gib']:.2f} GiB"
              f"  evict {a['forced_evictions']:>6,.0f}"
              + (f"  exit {a['exit']['code']}" if a['exit'] else ""))
    if want_summary:
        print(f"\n  wrote {write_summary(arms).relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
