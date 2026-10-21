#!/usr/bin/env python3
"""Time to OOM as a function of cache size, from measured inputs.

"Does cache size N prevent the OOM" has no answer without a duration: a worker that dies at
hour 30 is fine on a daily deploy and broken on a monthly one. This turns arms into hours.

Both quantities scale with the cached population:

  headroom(N) = ceiling - (baseline + slope * N)      room a full cache leaves
  accrual(N)  = per_workflow_accrual_per_hour * N     history growth at constant population
  hours(N)    = headroom(N) / accrual(N)

slope and baseline come from fitting RSS against sticky_cache_size during the ramp.
per_workflow_accrual comes from fitting RSS against TIME during the hold, where the population
is constant so every further byte is history.

Usage:  ./deploy/56-time-to-oom.py [--json out.json] [arm-dir ...]
Without arm dirs it reads every docs/results/data/arm-*/ it can find.
"""
import sys, json, pathlib, argparse

# Fallback only. Phase 1 pinned DOTNET_GCHeapHardLimit=0x1A0000000 and exported no
# dotnet_gc_total_available_bytes, so those arms have nothing to read. Phase 2's nolimit arms
# size to the host, where this constant is wrong, so read the ceiling from the arm's own series
# when present. Same rule as 57-report-data.py.
CEILING_GIB = 6.5          # DOTNET_GCHeapHardLimit=0x1A0000000


def arm_ceiling_gib(arm_dir):
    """The GC's own view of its budget for this arm, in GiB, or the phase 1 constant."""
    f = arm_dir / "dotnet_gc_total_available_bytes.json"
    if not f.exists():
        return CEILING_GIB
    try:
        vals = [float(v) for r in json.loads(f.read_text())["data"]["result"]
                for _, v in r["values"]]
    except Exception:
        return CEILING_GIB
    # Max, not last. Constant for a process's life, so they agree on clean data, but a last
    # sample landing in a scrape gap reads low.
    return (max(vals) / 1024**3) if vals else CEILING_GIB
GIB = 1024 ** 3
MIB = 1024 ** 2


def fit(xs, ys):
    """Least squares. Pairwise deltas are useless here: RSS moves in GC-sized steps."""
    n = len(xs)
    if n < 3:
        return None, None
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))
    d = n * sxx - sx * sx
    if not d:
        return None, None
    slope = (n * sxy - sx * sy) / d
    return slope, (sy - slope * sx) / n


def read_samples(path):
    """cached \t rss \t epoch, as written by 65-watch-arm.sh."""
    rows = []
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) >= 2:
            try:
                rows.append((float(f[0]), float(f[1]), float(f[2]) if len(f) > 2 else None))
            except ValueError:
                continue
    return rows


def analyse(arm_dir):
    s = arm_dir / "rss-vs-cache.tsv"
    if not s.exists():
        s = arm_dir / "arm-samples.tsv"
    if not s.exists():
        return None
    rows = [r for r in read_samples(s) if r[0] > 300]
    if len(rows) < 8:
        return None

    out = {"arm": arm_dir.name.replace("arm-", ""), "samples": len(rows),
           "ceiling_gib": arm_ceiling_gib(arm_dir)}

    out_top = max(r[0] for r in rows)
    # Ramp: RSS against population, EXCLUDING the plateau. Hold samples sit at constant
    # population while RSS climbs from history, so they tilt the slope up and drag the
    # intercept down. A synthetic arm built at 691 KB/wf and 0.60 GiB fit as 705 and 0.55.
    ramp = [r for r in rows if r[0] < out_top * 0.995] or rows
    slope, base = fit([r[0] for r in ramp], [r[1] for r in ramp])
    if slope is None or slope <= 0:
        return None
    out["slope_kb_per_wf"] = slope / 1024
    out["baseline_gib"] = base / GIB
    out["peak_cached"] = out_top
    out["ramp_samples"] = len(ramp)
    out["peak_rss_gib"] = max(r[1] for r in rows) / GIB

    # Hold: RSS against time at constant population. Every byte here is history accrual.
    top = out_top
    hold = [r for r in rows if r[0] >= top * 0.995 and r[2] is not None]
    if len(hold) >= 8:
        t0 = hold[0][2]
        a, _ = fit([r[2] - t0 for r in hold], [r[1] for r in hold])
        if a is not None and a > 0:
            out["accrual_mib_per_hour"] = a * 3600 / MIB
            out["accrual_kb_per_wf_per_hour"] = a * 3600 / 1024 / top
            out["hold_minutes"] = (hold[-1][2] - t0) / 60
    return out


def project(slope_kb, base_gib, accrual_kb_wf_hr, sizes, ceiling_gib=CEILING_GIB):
    rows = []
    for n in sizes:
        full = base_gib + slope_kb * n / MIB          # GiB at a full cache
        head = ceiling_gib - full
        acc = accrual_kb_wf_hr * n / MIB              # GiB per hour
        if head <= 0:
            hours, verdict = 0.0, "OOMs while filling"
        elif acc <= 0:
            hours, verdict = float("inf"), "stable"
        else:
            hours = head / acc
            verdict = ("under 1h" if hours < 1 else
                       "under a day" if hours < 24 else
                       "about a week" if hours < 24 * 7 else "stable")
        rows.append({"cache": n, "full_gib": full, "headroom_gib": head,
                     "accrual_gib_per_hour": acc, "hours_to_oom": hours, "verdict": verdict})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*")
    ap.add_argument("--json")
    a = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent / "docs/results/data"
    dirs = [pathlib.Path(d) for d in a.dirs] or sorted(p for p in root.glob("arm-*") if p.is_dir())
    arms = [x for x in (analyse(d) for d in dirs) if x]

    if not arms:
        print("No arm data with samples yet. Run an arm first.", file=sys.stderr)
        return 1

    ceilings = sorted({round(x["ceiling_gib"], 2) for x in arms})
    print("\n  Measured, against a per-arm ceiling: "
          + ", ".join(f"{c} GiB" for c in ceilings) + "\n")
    print(f"  {'arm':<14}{'slope KB/wf':>13}{'baseline GiB':>14}{'peak cached':>13}"
          f"{'peak GiB':>10}{'accrual MB/hr':>15}")
    for x in arms:
        print(f"  {x['arm']:<14}{x['slope_kb_per_wf']:>13,.0f}{x['baseline_gib']:>14,.2f}"
              f"{x['peak_cached']:>13,.0f}{x['peak_rss_gib']:>10,.2f}"
              f"{x.get('accrual_mib_per_hour', float('nan')):>15,.0f}")

    # Project from the arm that reached a steady population.
    usable = [x for x in arms if "accrual_kb_per_wf_per_hour" in x] or arms
    src = max(usable, key=lambda x: x["peak_cached"])
    acc = src.get("accrual_kb_per_wf_per_hour", 0.0)
    print(f"\n  Projecting from arm {src['arm']}: {src['slope_kb_per_wf']:,.0f} KB/wf, "
          f"{acc:,.2f} KB/wf/hour accrual")
    if acc == 0:
        print("  No hold-phase accrual measured yet, so hours are not projectable.")

    sizes = list(range(2000, 12001, 1000))
    # The SOURCE arm's ceiling, not a global one. A nolimit arm projected against the 6.5 GiB
    # hard limit answers a different experiment.
    rows = project(src["slope_kb_per_wf"], src["baseline_gib"], acc, sizes, src["ceiling_gib"])
    print(f"\n  {'cache':>7}{'full GiB':>11}{'headroom':>11}{'accrual GiB/h':>15}{'time to OOM':>14}  verdict")
    for r in rows:
        h = ("--" if r["hours_to_oom"] == 0 else
             "never" if r["hours_to_oom"] == float("inf") else f"{r['hours_to_oom']:,.1f} h")
        print(f"  {r['cache']:>7,}{r['full_gib']:>11,.2f}{r['headroom_gib']:>11,.2f}"
              f"{r['accrual_gib_per_hour']:>15,.3f}{h:>14}  {r['verdict']}")

    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(
            {"ceiling_gib": src["ceiling_gib"], "arms": arms, "projection": rows,
             "projected_from": src["arm"]}, indent=2))
        print(f"\n  wrote {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
