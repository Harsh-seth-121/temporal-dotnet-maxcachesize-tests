#!/usr/bin/env bash
# Run every pending arm in turn, launching and collecting each unattended.
#
#   ./deploy/64-run-remaining.sh                 # all pending arms, in order
#   ./deploy/64-run-remaining.sh --dry-run       # print the plan and stop
#
# Order and membership come from the run-state file, so this resumes: it picks up what is
# pending and skips what is collected. Killing it is safe. A launched arm keeps running on
# Azure, records itself and drains itself; a kill only delays collection.
#
# Arms are strictly sequential: they share one worker, and two at once invalidate both.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
DRIVER="$DRIVER_APP"
POLL="${POLL_SECONDS:-120}"
# Ramp plus a 75 minute hold plus drain. This is a backstop for a stuck arm, not an estimate.
MAX_WAIT_MIN="${MAX_WAIT_MIN:-200}"

say() { printf '\n\033[1m==> %s\033[0m  %s\n' "$*" "$(date +%H:%M)"; }

addr=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['address'])")
ns=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")
running_count() {
  temporal workflow count --query 'ExecutionStatus="Running"' \
    --address "$addr" --namespace "$ns" \
    --tls-cert-path "$SECRETS/client.pem" --tls-key-path "$SECRETS/client.key" 2>/dev/null \
  | awk -F': *' '/Total/{print $2}' | tr -d ' '
}

plan=$(python3 - "$STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for a in sorted(s["arms"], key=lambda a: a.get("order", 0)):
    if a.get("state") == "pending":
        print(f"{a['arm']}\t{a['cache']}\t{a['gc']}")
PY
)

if [ -z "$plan" ]; then echo "Nothing pending. All arms are collected."; exit 0; fi
echo "Pending arms, in order:"; printf '%s\n' "$plan" | sed 's/^/  /'
[ "${1:-}" = "--dry-run" ] && exit 0

while IFS=$'\t' read -r arm cache gc; do
  [ -z "$arm" ] && continue
  say "Launching $arm (cache $cache, GC $gc)"
  # ALLOW_NO_GC_LIMIT matters only on a nolimit arm, where a missing heap limit is the point.
  if [ "$gc" = "nolimit" ]; then
    ALLOW_NO_GC_LIMIT=1 "$ROOT/deploy/60-run-arm.sh" "$cache" nolimit
  else
    "$ROOT/deploy/60-run-arm.sh" "$cache" limit
  fi

  say "Waiting for $arm to finish"
  # Both conditions required. The driver also reports "finished" after a failure, and an arm
  # whose population is still running is not done.
  done_at=""
  deadline=$(( $(date +%s) + MAX_WAIT_MIN * 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$POLL"
    phase=$(curl -sf --max-time 20 "https://${DRIVER}.azurewebsites.net/" 2>/dev/null \
            | python3 -c "import json,sys;print(json.load(sys.stdin)['phase'])" 2>/dev/null || echo unreachable)
    left=$(running_count); left="${left:-unknown}"
    printf '  %s  phase=%-28s running=%s\n' "$(date +%H:%M)" "$phase" "$left"
    if [ "$phase" = "finished" ] && [ "$left" = "0" ]; then done_at=$(date +%H:%M); break; fi
  done

  if [ -z "$done_at" ]; then
    echo "  $arm did not finish within ${MAX_WAIT_MIN}m. Stopping here rather than starting" >&2
    echo "  another arm on top of it. Investigate, then re-run this script." >&2
    exit 1
  fi

  say "Collecting $arm"
  # Collection backfills Prometheus too, so Grafana covers the stretches this laptop slept.
  "$ROOT/deploy/62-collect-arm.sh" "$arm"
done <<< "$plan"

say "All pending arms are collected"
"$ROOT/deploy/57-report-data.py" --summary
