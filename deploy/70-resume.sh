#!/usr/bin/env bash
# Bring the harness back after a shutdown, stopping short of starting an arm.
#
# An arm is a 90-minute commitment that should start when someone is watching, so the last
# command is printed rather than run.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Observability"
# Named volumes, 30d retention, restart=unless-stopped, so these usually come back on their
# own. Starting them again is a no-op.
for c in "$PREFIX-prom" "$PREFIX-grafana"; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "  $c already up"
  elif docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    docker start "$c" >/dev/null && echo "  $c started"
  else
    echo "  $c MISSING. Run ./deploy/30-deploy-observability.sh" >&2
  fi
done

# Prometheus binds loopback only. Anything else publishes an unauthenticated admin surface on
# the LAN.
for i in $(seq 1 30); do
  curl -sf --max-time 3 http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && { echo "  prometheus ready"; break; }
  [ "$i" = 30 ] && { echo "  prometheus never became ready" >&2; exit 1; }
  sleep 2
done
echo "  grafana  http://127.0.0.1:3000"

say "Azure apps"
for app in "$PREFIX-worker" "$PREFIX-driver"; do
  state=$(az webapp show -g "$RG" -n "$app" --query state -o tsv 2>/dev/null || echo Absent)
  if [ "$state" = "Running" ]; then
    echo "  $app already running"
  elif [ "$state" = "Absent" ]; then
    echo "  $app does not exist. Run ./deploy/00-provision.sh and the deploy scripts" >&2; exit 1
  else
    az webapp start -g "$RG" -n "$app" --output none && echo "  $app started"
  fi
done

say "Waiting for the worker to serve"
for i in $(seq 1 40); do
  curl -sf --max-time 10 "https://${PREFIX}-worker.azurewebsites.net/" >/dev/null 2>&1 \
    && { echo "  worker serving"; break; }
  [ "$i" = 40 ] && { echo "  worker never came up; check the container log" >&2; exit 1; }
  sleep 15
done

say "Preflight"
# nolimit arms run with no DOTNET_GCHeapHardLimit on purpose; preflight fails a missing one by
# default because on a limit arm it means a dropped app setting. Ask the state file which arm
# is next. 60-run-arm.sh DELETES the setting for a nolimit arm and never restores it, so the
# worker stays limitless until the next limit arm sets it again.
gcmode=$(python3 "$ROOT/deploy/lib-state-summary.py" "$STATE" --next-gc 2>/dev/null || echo limit)
echo "  next arm runs with GC mode: $gcmode"
if [ "$gcmode" = "nolimit" ]; then
  ALLOW_NO_GC_LIMIT=1 ./deploy/40-preflight.sh || { echo "  preflight failed, fix before starting an arm" >&2; exit 1; }
else
  ./deploy/40-preflight.sh || { echo "  preflight failed, fix before starting an arm" >&2; exit 1; }
fi

say "Where things stand"
# From the state file, never hardcoded. A hardcoded message goes stale the moment an arm runs;
# this script once described an arm superseded two runs earlier.
python3 "$ROOT/deploy/lib-state-summary.py" "$STATE" \
  || echo "  $STATE unreadable. Read it by hand before doing anything."

cat <<'MSG'

  Arms are strictly sequential: they share one worker, and two at once invalidate both.
  Do not start one until the state file says the unattended path is in place, because an arm
  that outlives the laptop loses its series to the scrape gap and keeps billing Actions.

      ./deploy/71-park.sh      park safely before closing the laptop
      /resume-cache-test       the full resume checklist

  A stopped App Service still bills its plan, about $3.70/day.
MSG
