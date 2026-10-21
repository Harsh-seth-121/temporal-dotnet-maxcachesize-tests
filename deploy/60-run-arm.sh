#!/usr/bin/env bash
# Launches one arm, then exits. The arm keeps running on Azure without this laptop.
#
#   ./deploy/60-run-arm.sh 10000
#   ./deploy/60-run-arm.sh 10000 nolimit
#
# Nothing runs in the foreground: the worker samples itself to /home/LogFiles every 30s, the
# driver terminates its own population after the profile's holdMinutes, and
# ./deploy/62-collect-arm.sh turns the samples into series later.
#
# Arms are strictly sequential: they share one worker, and two at once invalidate both.
# Check "$STATE" before launching one.
set -euo pipefail

CACHE="${1:?usage: 60-run-arm.sh <maxCachedWorkflows> [limit|nolimit]}"
# Phase 2 runs every cache size twice, with and without the GC hard limit. The mode is part of
# the arm identity, not an ambient env var: the arm name is the metric tag and the export query
# key, so two arms sharing a cache size must still be tellable apart.
GC_MODE="${2:-limit}"            # limit | nolimit
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
WORKER="$WORKER_APP"
DRIVER="$DRIVER_APP"
# Informational. Arm length is the profile's holdMinutes plus ramp; expect_done_at comes from
# cap_minutes in the run-state file. Kept so old command lines in the docs still run.
CAP_MINUTES="${CAP_MINUTES:-90}"
# Validate before anything touches Azure. A typo like "nolimits" falls through to the limit
# path, producing a duplicate of an arm we have while the one we wanted stays missing.
case "$GC_MODE" in
  limit|nolimit) ;;
  *) echo "FATAL: GC_MODE must be 'limit' or 'nolimit', got '$GC_MODE'" >&2
     echo "       usage: 60-run-arm.sh <maxCachedWorkflows> [limit|nolimit]" >&2
     exit 1 ;;
esac
ARM="c${CACHE}"
# `if`, not `[[ ... ]] && ARM=...`: under `set -e` a false test makes the AND-list exit
# non-zero at top level, so the common case (limit) would kill the script here.
if [[ "$GC_MODE" == "nolimit" ]]; then ARM="${ARM}-nolimit"; fi
# Stable across arms. The worker restarts between arms anyway, so a per-arm queue name buys no
# isolation and adds a way for worker and driver to disagree.
TASK_QUEUE="$(python3 -c "import json;print(json.load(open('${SECRETS_DIR:-$HOME/.config/temporal-cache-test}/testconfig.json'))['arms'][0]['taskQueue'])")"
OUT="$ROOT/docs/results/data/arm-${ARM}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
tok() { tr -d '\n' < "$SECRETS/metrics_token"; }
wurl="https://${WORKER}.azurewebsites.net"

m() {  # m <metric> <endpoint> -> summed value, or empty if the metric is absent.
  # Must not fail the script. Under `set -e` with pipefail a grep matching nothing exits 1 and
  # kills the run, and a counter never incremented is absent from the exposition, which is
  # normal before the worker has handled a task.
  local out
  out=$(curl -sf --max-time 20 -H "Authorization: Bearer $(tok)" "$wurl/$2" 2>/dev/null || true)
  printf '%s\n' "$out" | awk -v k="$1" '$1 ~ "^"k {s+=$NF; n++} END{if(n)print s+0}' || true
}

addr=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['address'])")
ns=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")

# Refuse to start on top of a live arm. The runner detaches, so nothing else notices a previous
# arm still out there: one shared worker, mixed populations, meaningless memory slopes.
# ALLOW_CONCURRENT_ARM=1 overrides, for a state file left stale by a dead launch.
inflight=$("$ROOT/deploy/lib-state-summary.py" "$STATE" --inflight 2>/dev/null || true)
if [ -n "$inflight" ] && [ "$inflight" != "$ARM" ] && [ "${ALLOW_CONCURRENT_ARM:-0}" != "1" ]; then
  echo "FATAL: arm $inflight is still in flight. Arms share one worker; two at once invalidate both." >&2
  echo "       Collect it first:  ./deploy/62-collect-arm.sh $inflight" >&2
  echo "       Or, if that arm is really gone:  ./deploy/71-park.sh" >&2
  exit 1
fi

say "Arm $ARM: setting cache size to $CACHE (GC mode: $GC_MODE)"
# Setting an app setting restarts the app, which clears the cache. Required: terminated
# workflows linger in a worker's cache, so without a restart this arm inherits the previous
# one's residents.
#
# TASK_QUEUE is set here, not only at deploy time. The driver reads it from the shared config;
# if the two disagree the driver starts workflows on a queue nobody polls, the ramp "succeeds",
# and the cache stays empty.
#
# GC settings are re-applied every arm, not left to 10-deploy-workers.sh. Arms run back to back
# against one long-lived app, so a limit arm following a nolimit arm would otherwise run with no
# ceiling. gcServer=1 and GCDynamicAdaptationMode=0 are pinned on BOTH paths so the hard limit
# stays the only variable between the halves of the matrix; DATAS resizes the heap on its own.
if [[ "$GC_MODE" == "limit" ]]; then
  az webapp config appsettings set -g "$RG" -n "$WORKER" --output none \
    --settings MAX_CACHED_WORKFLOWS="$CACHE" ARM="$ARM" TASK_QUEUE="$TASK_QUEUE" \
      DOTNET_gcServer=1 DOTNET_GCDynamicAdaptationMode=0 \
      DOTNET_GCHeapHardLimit=0x1A0000000
else
  az webapp config appsettings set -g "$RG" -n "$WORKER" --output none \
    --settings MAX_CACHED_WORKFLOWS="$CACHE" ARM="$ARM" TASK_QUEUE="$TASK_QUEUE" \
      DOTNET_gcServer=1 DOTNET_GCDynamicAdaptationMode=0
  # DELETE, not set-to-empty. An empty app setting is still a setting: the runtime parses ""
  # as zero, and a zero hard limit is a ceiling of nothing, not no ceiling. Absence is the only
  # way to say "no hard limit".
  # || true: deleting an absent setting is the normal case for consecutive nolimit arms, and
  # under set -e an unguarded non-zero aborts before any workflow starts.
  az webapp config appsettings delete -g "$RG" -n "$WORKER" --output none \
    --setting-names DOTNET_GCHeapHardLimit || true
  # For any preflight run from inside this arm: a missing limit is the point here, not a
  # misconfiguration to fail on.
  export ALLOW_NO_GC_LIMIT=1
fi

say "Draining the namespace first"
# BEFORE waiting for an empty cache. A leftover driver keeps feeding the queue, the worker keeps
# caching, and the wait loop below never succeeds.
az webapp stop -g "$RG" -n "$DRIVER" --output none 2>/dev/null || true
# Terminate is a batch op against eventually-consistent visibility, so one pass misses anything
# mid-start. One pass once left 134 of ~7,200 running, and those keep heartbeating, so the
# empty-cache wait below deadlocks while looking slow.
tq() { temporal --address "$addr" --namespace "$ns" \
         --tls-cert-path "$SECRETS/client.pem" --tls-key-path "$SECRETS/client.key" "$@"; }
drained=no
for pass in 1 2 3 4 5 6; do
  tq workflow terminate --query 'ExecutionStatus="Running"' \
     --reason "starting arm $ARM" --yes >/dev/null 2>&1 || true
  sleep 20
  left=$(tq workflow count --query 'ExecutionStatus="Running"' 2>/dev/null \
         | awk -F': *' '/Total/{print $2}' | tr -d ' ')
  left="${left:-unknown}"
  echo "  pass $pass: $left still running"
  if [ "$left" = "0" ]; then drained=yes; break; fi
done
if [ "$drained" != "yes" ]; then
  echo "FATAL: namespace did not drain after 6 passes ($left running). Starting the arm now" >&2
  echo "       would mix leftover workflows into the population and corrupt the memory slope." >&2
  exit 1
fi

# Terminating a workflow does NOT evict it from a worker's cache: after a drain the cache sits
# non-zero with nothing running. Only a restart clears it.
say "Restarting the worker to guarantee an empty cache"
az webapp restart -g "$RG" -n "$WORKER" --output none 2>/dev/null || true
sleep 30

say "Waiting for the worker to come back with an empty cache"
for i in $(seq 1 40); do
  body=$(curl -sf --max-time 10 "$wurl/" 2>/dev/null || true)
  if [[ "$body" == arm=* && "$body" == *"cache=$CACHE"* ]]; then
    sz=$(m temporal_sticky_cache_size metrics)
    echo "  $body  cached=${sz:-0}"
    [[ "${sz:-0}" == "0" ]] && break
  fi
  sleep 15
done

say "Confirming worker and driver agree on the task queue"
wq=$(curl -sf --max-time 15 "$wurl/" 2>/dev/null | grep -oE 'queue=[^ ]+' | cut -d= -f2 || true)
if [[ "$wq" != "$TASK_QUEUE" ]]; then
  echo "  FATAL: worker polls '$wq' but the driver will start on '$TASK_QUEUE'."
  echo "  The ramp would appear to succeed while the cache stayed empty."
  exit 1
fi
echo "  both on $TASK_QUEUE"

say "Confirming the namespace is clear"
tq() { temporal workflow count --query 'ExecutionStatus="Running"' \
       --address "$addr" --namespace "$ns" \
       --tls-cert-path "$SECRETS/client.pem" --tls-key-path "$SECRETS/client.key" \
       2>/dev/null | grep -oE '[0-9]+' | head -1; }
echo "  running workflows: $(tq)"

say "Baseline before load"
mkdir -p "$OUT"
curl -sf --max-time 20 -H "Authorization: Bearer $(tok)" "$wurl/metrics/runtime" > "$OUT/baseline-runtime.txt" || true
grep -E "^(process_resident|dotnet_gc_total_available|container_memory_limit)" "$OUT/baseline-runtime.txt" | sed 's/^/  /' || true

say "Starting the driver (profile=oom)"
# The drain step above STOPS the driver, and az webapp deploy succeeds against a stopped app
# and leaves it stopped. Without the start below the ramp never begins.
# Settings and start, NOT a redeploy: the driver zip is ~80 MB of self-contained .NET that does
# not change between arms, while app settings are a few hundred bytes and restart the app by
# themselves. Redeploy only on a code change: ./deploy/20-deploy-driver.sh.
az webapp config appsettings set -g "$RG" -n "$DRIVER" --output none --settings \
  PROFILE=oom START_CONCURRENCY="${START_CONCURRENCY:-24}" \
  RESIDENT_HORIZON_HOURS="${RESIDENT_HORIZON_HOURS:-12}"
az webapp start -g "$RG" -n "$DRIVER" --output none 2>/dev/null || true

# Assert the ramp begins. A deployed-but-not-running driver looks like a working one until you
# notice the cache never moves.
for i in $(seq 1 20); do
  ph=$(curl -sf --max-time 12 "https://${DRIVER}.azurewebsites.net/" 2>/dev/null \
       | python3 -c "import json,sys;print(json.load(sys.stdin)['phase'])" 2>/dev/null || true)
  [[ "$ph" == running:* ]] && { echo "  driver $ph"; break; }
  [[ $i -eq 20 ]] && { echo "  FATAL: driver never reached a running phase (last: ${ph:-unreachable})"; exit 1; }
  sleep 15
done

# Mark launched BEFORE the wait, not after. If the laptop goes away here the population is out
# there billing, and 71-park.sh finds it only by reading this file.
# Record the real duration rather than falling back to CAP_MINUTES: ramp is population over
# achieved start rate, hold comes from the profile. The cap-derived estimate was 50 minutes out
# on arm 1.
_target=$(python3 -c "import json;p=json.load(open('$SECRETS/testconfig.json'));print(p['profiles']['oom']['targetOpenPerQueue'])" 2>/dev/null || echo 10000)
_hold=$(python3 -c "import json;p=json.load(open('$SECRETS/testconfig.json'));print(p['profiles']['oom'].get('holdMinutes',75))" 2>/dev/null || echo 75)
# Measured. Serial starts ran 2 to 3.9/s depending on worker load; the parallel ramp reaches
# the profile's nominal rate. Override with RAMP_STARTS_PER_SEC.
_rate="${RAMP_STARTS_PER_SEC:-4}"
_mins=$(python3 -c "print(int($_target/$_rate/60) + $_hold + 5)")
echo "  expecting roughly ${_mins} minutes: ramp at ${_rate}/s plus a ${_hold}m hold"
"$ROOT/deploy/lib-state-set.py" "$ARM" launched "--minutes=$_mins" || true

say "Launched. This script is done; the arm is not."
cat <<MSG

  Arm $ARM is running on Azure and no longer needs this laptop.

  The worker samples itself every 30 s into /home/LogFiles/samples/arm-$ARM-<start>.tsv, which
  is Azure Files backed and survives a kernel kill. The driver holds for the profile's
  holdMinutes and then terminates its own population, so the arm ends itself rather than
  billing until someone notices. Close the lid.

  Expected done:  $(python3 -c "
import json,pathlib
s=json.loads(pathlib.Path('$STATE').read_text())
print(next((a.get('expect_done_at') or '?' for a in s['arms'] if a['arm']=='$ARM'), '?'))
" 2>/dev/null || echo "see $STATE")

  Collect it any time after that:

      ./deploy/62-collect-arm.sh $ARM

  That downloads the samples, converts them to the series the report assembler reads, records
  the exit code and marks the arm collected. Nothing else to do in the meantime.

MSG
