#!/usr/bin/env python3
"""Turn the worker sampler's TSV into the per-metric JSON files 57-report-data.py reads.

    ./deploy/lib-tsv-to-series.py <samples.tsv> <arm-dir>

Input rows are  <unix seconds>\t<metric name with labels>\t<value>  as written by
src/CacheTest.Worker/MetricsSampler.cs.

Output is one file per metric family, shaped exactly like a Prometheus query_range response, so
nothing downstream has to learn a second format:

    {"data": {"result": [{"metric": {...labels...}, "values": [[ts, "value"], ...]}]}}

Histogram families keep _sum, _count and _bucket as separate files: that is how they arrive
from Prometheus and how the assembler asks for them.
"""
import collections
import json
import pathlib
import sys


def parse_labels(blob):
    """`{arm="c8000",le="5"}` -> dict. Values here never contain a comma or a quote."""
    out = {}
    for part in blob.strip("{}").split(","):
        if "=" not in part:
            continue
        k, _, v = part.partition("=")
        out[k.strip()] = v.strip().strip('"')
    return out


def main():
    src = pathlib.Path(sys.argv[1])
    dest = pathlib.Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)

    # metric name -> label-signature -> list of [ts, value]
    acc = collections.defaultdict(lambda: collections.defaultdict(list))
    labels_of = {}
    skipped = 0

    for raw in src.read_text().splitlines():
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3:
            skipped += 1
            continue
        ts, ident, value = parts
        name, _, lbl = ident.partition("{")
        try:
            ts = int(float(ts))
            float(value)
        except ValueError:
            skipped += 1
            continue
        sig = lbl
        acc[name][sig].append([ts, value])
        labels_of[(name, sig)] = parse_labels("{" + lbl) if lbl else {}

    for name, by_sig in acc.items():
        result = []
        for sig, values in by_sig.items():
            # Sorted and de-duplicated. A restart can replay a second within one file. The
            # assembler takes max() so a duplicate is harmless there, but a later diff is not.
            seen = {}
            for ts, v in values:
                seen[ts] = v
            result.append({"metric": dict(labels_of[(name, sig)], __name__=name),
                           "values": [[t, seen[t]] for t in sorted(seen)]})
        (dest / f"{name}.json").write_text(
            json.dumps({"status": "success", "data": {"resultType": "matrix", "result": result}}))

    print(f"  {len(acc)} metric families -> {dest}"
          + (f"  ({skipped} unparseable rows skipped)" if skipped else ""))


if __name__ == "__main__":
    main()
