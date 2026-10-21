#!/usr/bin/env bash
# Collect every launched arm from its own worker, then print the comparison.
#
#   ./deploy/68-collect-all.sh
#
# Safe before the arms finish: it takes whatever each worker has written so far. Samples are
# cumulative on /home/LogFiles, so a later run supersedes an earlier one.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1

mapfile -t rows < <(python3 - "$STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for a in sorted(s["arms"], key=lambda a: a.get("order", 0)):
    if a.get("state") in ("launched", "collected"):
        print(f"{a['arm']}\t{a['worker_app']}")
PY
)
[ "${#rows[@]}" -eq 0 ] && { echo "No arms to collect."; exit 0; }

for row in "${rows[@]}"; do
  IFS=$'\t' read -r arm app <<< "$row"
  printf '\n\033[1m=== %s from %s ===\033[0m\n' "$arm" "$app"
  # One failed collection must not stop the other five. Its samples stay on the worker.
  WORKER_APP="$app" "$ROOT/deploy/62-collect-arm.sh" "$arm" || \
    echo "  collect failed for $arm; retry with WORKER_APP=$app ./deploy/62-collect-arm.sh $arm" >&2
done

printf '\n\033[1m==> Comparison\033[0m\n'
"$ROOT/deploy/57-report-data.py" --summary
