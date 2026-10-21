#!/usr/bin/env python3
"""Turn the worker sampler's TSV into an OpenMetrics file promtool can backfill into Prometheus.

    ./deploy/lib-tsv-to-openmetrics.py <samples.tsv> <out.om> \
        [--job temporal-worker] --instance <host>:<port>

The worker records itself to /home/LogFiles every 30s, which is what makes an arm survivable
with the laptop shut. Grafana reads Prometheus, which holds only the minutes the laptop was
awake. Backfilling closes that gap so a post mortem sees the whole arm on the same dashboards.

Format rules, learned from promtool refusing files:
  * samples sorted by series, then by timestamp
  * a TYPE line before each family's samples
  * timestamps in seconds, file ending with "# EOF"
Everything is declared a gauge. Counter is the truthful type, but declaring a counter whose
name does not end in `_total` makes the parser reject the file, and nothing downstream reads
the type: rate() and increase() work off the samples.
"""
import collections
import pathlib
import sys

def flag(name, default):
    for i, a in enumerate(sys.argv):
        if a == name and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


# Positional args only: a flag and the value after it are both dropped.
_skip = set()
for _i, _a in enumerate(sys.argv):
    if _a.startswith("--"):
        _skip.add(_i)
        _skip.add(_i + 1)
args = [a for i, a in enumerate(sys.argv) if i > 0 and i not in _skip]

job = flag("--job", "temporal-worker")
# The instance label has to match what a real scrape attached, or the backfilled series
# sits beside the scraped one and every dashboard draws two lines. Only the caller knows
# which worker app this arm ran on, so it has to say.
instance = flag("--instance", "")
if not instance:
    sys.exit("--instance <host>:<port> is required: it must match the scrape target")

src, dest = pathlib.Path(args[0]), pathlib.Path(args[1])

# series identity -> [(ts, value)]
rows = collections.defaultdict(list)
for raw in src.read_text().splitlines():
    if not raw or raw.startswith("#"):
        continue
    parts = raw.split("\t")
    if len(parts) != 3:
        continue
    ts, ident, value = parts
    try:
        ts = int(float(ts))
        float(value)
    except ValueError:
        continue
    name, _, lbl = ident.partition("{")
    # job and instance are what a scrape would have attached.
    extra = f'job="{job}",instance="{instance}"'
    ident = f"{name}{{{lbl.rstrip('}')},{extra}}}" if lbl else f"{name}{{{extra}}}"
    rows[(name, ident)].append((ts, value))

out = []
for name in sorted({n for n, _ in rows}):
    out.append(f"# TYPE {name} gauge")
    for (n, ident), samples in sorted(rows.items()):
        if n != name:
            continue
        seen = {}
        for ts, v in samples:
            seen[ts] = v           # a restart can replay a second; last write wins
        for ts in sorted(seen):
            out.append(f"{ident} {seen[ts]} {ts}")
out.append("# EOF")
dest.write_text("\n".join(out) + "\n")

span = [t for v in rows.values() for t, _ in v]
print(f"  {len(rows)} series, {sum(len(v) for v in rows.values()):,} samples -> {dest}")
if span:
    print(f"  covering {max(span) - min(span)} seconds")
