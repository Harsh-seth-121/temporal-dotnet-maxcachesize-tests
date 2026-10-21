#!/usr/bin/env bash
# Launch every arm at once, one worker app each, then exit.
#
#   ./deploy/66-run-all.sh
#
# Six arms in sequence cost ~9 hours, six at once ~90 minutes, and parallel arms see the same
# namespace conditions instead of being staggered across a day.
#
# Each arm gets its own worker app on its own App Service plan: no shared heap, cache or 8 GiB
# budget. Arm-to-worker mapping lives in the run-state file.
#
# The laptop is free once this returns. Each worker records itself to /home/LogFiles and the
# driver terminates the population when its hold ends.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
DRIVER="$DRIVER_APP"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
tok() { tr -d '\n' < "$SECRETS/metrics_token"; }

addr=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['address'])")
ns=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")
tq() { temporal --address "$addr" --namespace "$ns" \
         --tls-cert-path "$SECRETS/client.pem" --tls-key-path "$SECRETS/client.key" "$@"; }

# ARMS limits the run to a named subset, comma or space separated; default is every arm in the
# state file. The alternative, editing the config down to those arms, is how a driver came to
# carry a stale arm list and ramp thousands of workflows onto a queue nobody polled.
mapfile -t plan < <(ARMS="${ARMS:-}" python3 - "$STATE" <<'PY'
import json, os, sys, re
s = json.load(open(sys.argv[1]))
pick = [w for w in re.split(r"[,\s]+", os.environ.get("ARMS", "")) if w]
known = {a["arm"] for a in s["arms"]}
missing = [w for w in pick if w not in known]
if missing:
    sys.exit(f"ARMS names arms not in the state file: {missing}. Known: {sorted(known)}")
for a in sorted(s["arms"], key=lambda a: a.get("order", 0)):
    if pick and a["arm"] not in pick:
        continue
    print(f"{a['arm']}\t{a['cache']}\t{a['gc']}\t{a['worker_app']}\t{a['task_queue']}")
PY
)
[ "${#plan[@]}" -eq 0 ] && {
  echo "No arms selected from $STATE${ARMS:+ with ARMS='$ARMS'}." >&2
  echo "A misspelt name in ARMS lands here: the selector rejects unknown names." >&2
  exit 1
}

say "Arms"
printf '%s\n' "${plan[@]}" | awk -F'\t' '{printf "  %-16s cache %-6s %-8s %s\n", $1, $2, $3, $4}'

say "Draining the namespace"
# Before anything else. Leftovers now mix into all six populations at once, not one.
drained=no
for pass in 1 2 3 4 5 6; do
  tq workflow terminate --query 'ExecutionStatus="Running"' --reason "starting all arms" --yes >/dev/null 2>&1 || true
  sleep 20
  left=$(tq workflow count --query 'ExecutionStatus="Running"' 2>/dev/null | awk -F': *' '/Total/{print $2}' | tr -d ' ')
  left="${left:-unknown}"
  echo "  pass $pass: $left still running"
  [ "$left" = "0" ] && { drained=yes; break; }
done
[ "$drained" != "yes" ] && { echo "FATAL: namespace did not drain ($left running)." >&2; exit 1; }

say "Configuring workers"
# Applied in parallel. Each set restarts its own app, which is how each arm gets an empty
# cache: terminating workflows does not evict them from a worker's cache.
pids=()
for row in "${plan[@]}"; do
  IFS=$'\t' read -r arm cache gc app queue <<< "$row"
  (
    if [ "$gc" = "limit" ]; then
      az webapp config appsettings set -g "$RG" -n "$app" --output none --settings \
        ARM="$arm" MAX_CACHED_WORKFLOWS="$cache" TASK_QUEUE="$queue" \
        DOTNET_gcServer=1 DOTNET_GCDynamicAdaptationMode=0 \
        DOTNET_GCHeapHardLimit=0x1A0000000
    else
      az webapp config appsettings set -g "$RG" -n "$app" --output none --settings \
        ARM="$arm" MAX_CACHED_WORKFLOWS="$cache" TASK_QUEUE="$queue" \
        DOTNET_gcServer=1 DOTNET_GCDynamicAdaptationMode=0
      # DELETE, not set-to-empty. An empty app setting is still a setting: the runtime parses
      # "" as zero, and a zero hard limit is a ceiling of nothing rather than no ceiling.
      az webapp config appsettings delete -g "$RG" -n "$app" --output none \
        --setting-names DOTNET_GCHeapHardLimit || true
    fi
    az webapp start -g "$RG" -n "$app" --output none 2>/dev/null || true
    echo "  $arm -> $app ($gc)"
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

say "Waiting for every worker to serve with an empty cache"
for row in "${plan[@]}"; do
  IFS=$'\t' read -r arm cache gc app queue <<< "$row"
  ok=no
  for i in $(seq 1 40); do
    body=$(curl -sf --max-time 10 "https://${app}.azurewebsites.net/" 2>/dev/null || true)
    if [[ "$body" == arm=* && "$body" == *"cache=$cache"* && "$body" == *"queue=$queue"* ]]; then
      sz=$(curl -sf --max-time 20 -H "Authorization: Bearer $(tok)" \
             "https://${app}.azurewebsites.net/metrics" 2>/dev/null \
           | awk '/^temporal_sticky_cache_size/{s+=$NF} END{print s+0}')
      if [ "${sz:-0}" = "0" ]; then echo "  $arm ready: $body"; ok=yes; break; fi
    fi
    sleep 15
  done
  # A worker that never comes back measures nothing while the other five look fine.
  [ "$ok" != "yes" ] && { echo "FATAL: $app never served an empty cache for $arm" >&2; exit 1; }
done

say "Starting the driver"
# Settings only, not a redeploy: the driver's code does not change between runs and its zip is
# 58 MB. PROFILE=oom ramps every arm in the config in lockstep.
# APS_LIMIT overrides what was baked in at deploy time. The namespace ceiling is 500, not the
# 1000 an older config carried, and a preflight checking the wrong ceiling waves through a run
# Temporal then throttles. Throttling reads as cache slowness in the latency series.
az webapp config appsettings set -g "$RG" -n "$DRIVER" --output none --settings \
  PROFILE=oom START_CONCURRENCY="${START_CONCURRENCY:-24}" \
  APS_LIMIT="${APS_LIMIT:-500}" \
  ARMS="$(printf '%s\n' "${plan[@]}" | cut -f1 | paste -sd, -)" \
  RESIDENT_HORIZON_HOURS="${RESIDENT_HORIZON_HOURS:-6}"
az webapp start -g "$RG" -n "$DRIVER" --output none 2>/dev/null || true

for i in $(seq 1 24); do
  ph=$(curl -sf --max-time 12 "https://${DRIVER}.azurewebsites.net/" 2>/dev/null \
       | python3 -c "import json,sys;print(json.load(sys.stdin)['phase'])" 2>/dev/null || true)
  [[ "$ph" == running:* ]] && { echo "  driver $ph"; break; }
  [ "$i" = 24 ] && { echo "FATAL: driver never reached a running phase (last: ${ph:-unreachable})" >&2; exit 1; }
  sleep 15
done

say "Checking the driver is ramping the arms we configured"
# The driver's arm list is baked into its zip at deploy time, so a driver deployed before the
# arms were written ramps the old set: thousands of workflows on a queue nobody polls, every
# worker idle, and the run looking healthy from outside. Compare and, on a mismatch, drain.
want=$(printf '%s\n' "${plan[@]}" | cut -f5 | sort | tr '\n' ' ')
got=$(curl -sf --max-time 20 "https://${DRIVER}.azurewebsites.net/" \
      | python3 -c "import json,sys;print(' '.join(sorted(a['taskQueue'] for a in json.load(sys.stdin)['arms'])))" 2>/dev/null || true)
got="$got "
if [ "$want" != "$got" ]; then
  echo "FATAL: the driver is ramping a different set of queues than the workers serve." >&2
  echo "  configured: $want" >&2
  echo "  driver:     ${got:-unreadable}" >&2
  az webapp stop -g "$RG" -n "$DRIVER" --output none 2>/dev/null || true
  for pass in 1 2 3 4 5 6; do
    tq workflow terminate --query 'ExecutionStatus="Running"' --reason "wrong queue set" --yes >/dev/null 2>&1 || true
    sleep 20
    _l=$(tq workflow count --query 'ExecutionStatus="Running"' 2>/dev/null | awk -F': *' '/Total/{print $2}' | tr -d ' ')
    echo "  drained to ${_l:-unknown}" >&2
    [ "${_l:-x}" = "0" ] && break
  done
  echo "  Redeploy the driver so its config carries these arms, then re-run this script." >&2
  exit 1
fi
echo "  driver is ramping all ${#plan[@]} queues"

say "Recording the launch"
_hold=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['profiles']['oom'].get('holdMinutes',75))")
_target=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['profiles']['oom']['targetOpenPerQueue'])")
# Pacing is per index across all arms at once, so wall-clock ramp length matches a single
# arm's: one index per tick for every queue together.
_mins=$(python3 -c "print(int($_target/12.5/60) + $_hold + 10)")
echo "  expecting roughly ${_mins} minutes"
for row in "${plan[@]}"; do
  IFS=$'\t' read -r arm _ _ _ _ <<< "$row"
  "$ROOT/deploy/lib-state-set.py" "$arm" launched "--minutes=$_mins" || true
done

say "All arms launched"
cat <<MSG

  Six arms are running on Azure, one worker each. Nothing here needs this laptop: every worker
  samples itself every 30 s to /home/LogFiles, and the driver terminates the whole population
  when its hold ends.

  Watch:    ./deploy/67-watch-all.sh
  Collect:  ./deploy/68-collect-all.sh      once they are done

MSG
