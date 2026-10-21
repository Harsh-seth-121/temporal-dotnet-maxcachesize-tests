#!/usr/bin/env bash
# Pre-run checks. All cheap, each catching a failure that otherwise surfaces as a wrong answer
# hours into a run.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
fail=0

ck() { # ck <label> <ok|warn|no> <detail>
  if [[ "$2" == "ok" ]]; then printf '  \033[32mPASS\033[0m %-42s %s\n' "$1" "${3:-}"
  # warn is a third state, not a soft fail: it prints and leaves $fail alone, so the run still
  # starts. Some conditions are a misconfiguration on one arm and the point of the next.
  # Anything wrong on every arm stays a no.
  elif [[ "$2" == "warn" ]]; then printf '  \033[33mWARN\033[0m %-42s %s\n' "$1" "${3:-}"
  else printf '  \033[31mFAIL\033[0m %-42s %s\n' "$1" "${3:-}"; fail=1; fi
}

echo "Config and secrets"
[[ -f "$SECRETS/testconfig.json" ]] && ck "config present" ok || ck "config present" no "config/testconfig.json missing"
for f in client.pem client.key metrics_token; do
  [[ -n "$(secret "$f" 2>/dev/null)" ]] && ck "certs/$f" ok || ck "certs/$f" no "missing"
done
if [[ -f "$SECRETS/testconfig.json" ]]; then
  if grep -q "<namespace>" "$SECRETS/testconfig.json"; then
    ck "config has no placeholders" no "still contains <namespace>"
  else ck "config has no placeholders" ok; fi
fi
# Gitignoring them is pointless if one is already in the index.
if git -C "$ROOT" ls-files --error-unmatch certs/client.pem >/dev/null 2>&1; then
  ck "cert NOT tracked by git" no "client.pem IS TRACKED - remove it from the index"
else ck "cert NOT tracked by git" ok; fi

echo
echo "Azure apps"
for app in "$WORKER_APP" "$DRIVER_APP"; do
  state=$(az webapp show -g "$RG" -n "$app" --query state -o tsv 2>/dev/null)
  [[ "$state" == "Running" ]] && ck "$app running" ok || ck "$app running" no "state=${state:-absent}"
  ao=$(az webapp config show -g "$RG" -n "$app" --query alwaysOn -o tsv 2>/dev/null)
  # Without Always On the app unloads after 20 idle minutes, taking the sticky cache with it.
  [[ "$ao" == "true" ]] && ck "$app alwaysOn" ok || ck "$app alwaysOn" no "alwaysOn=$ao"
  https=$(az webapp show -g "$RG" -n "$app" --query httpsOnly -o tsv 2>/dev/null)
  [[ "$https" == "true" ]] && ck "$app httpsOnly" ok || ck "$app httpsOnly" no "bearer token could cross cleartext"
done

echo
echo "Worker reachability and memory ceiling"
TOKEN=$(tr -d "\n" < "$SECRETS/metrics_token" 2>/dev/null || echo "")
for app in "$WORKER_APP"; do
  url="https://${app}.azurewebsites.net"
  body=$(curl -sf --max-time 25 "$url/" 2>/dev/null)
  # Must be OUR worker, not the Azure placeholder page. An undeployed app serves
  # <!DOCTYPE html> and passes a liveness-only check.
  if [[ "$body" == arm=* ]]; then
    ck "worker is our worker" ok "$body"
    # Running cache vs app setting: catches a failed restart still holding the previous arm's
    # value.
    want=$(az webapp config appsettings list -g "$RG" -n "$app" \
           --query "[?name=='MAX_CACHED_WORKFLOWS'].value" -o tsv 2>/dev/null)
    if [[ -n "$want" && "$body" == *"cache=$want"* ]]; then
      ck "running cache matches app setting" ok "cache=$want"
    else
      ck "running cache matches app setting" no "setting=$want but running: $body"
    fi
  elif [[ -n "$body" ]]; then
    ck "worker is our worker" no "responding but not deployed (Azure placeholder page)"
  else
    ck "worker is our worker" no "no response"
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$url/metrics" 2>/dev/null)
  # An unauthenticated 200 means the token check is not wired on a public endpoint.
  [[ "$code" == "401" ]] && ck "worker /metrics requires auth" ok \
    || ck "worker /metrics requires auth" no "unauthenticated request returned $code"
  n=$(curl -sf --max-time 25 -H "Authorization: Bearer $TOKEN" "$url/metrics" 2>/dev/null | grep -c '^temporal_')
  [[ "${n:-0}" -gt 0 ]] && ck "worker exports metrics" ok "$n series" \
    || ck "worker exports metrics" no "no temporal_ series"
done

echo
echo "Memory ceiling (decides whether OOM is predictable at all)"
rt=$(curl -sf --max-time 25 -H "Authorization: Bearer $TOKEN" \
     "https://${WORKER_APP}.azurewebsites.net/metrics/runtime" 2>/dev/null || true)
cg=$(echo "$rt" | grep '^container_memory_limit_bytes' | awk '{print $NF}')
av=$(echo "$rt" | grep '^dotnet_gc_total_available_bytes' | awk '{print $NF}')
cores=$(echo "$rt" | grep '^process_available_cores' | awk '{print $NF}')

if [[ -n "$cg" ]]; then
  ck "cgroup memory limit visible" ok "$(python3 -c "print(f'{$cg/1073741824:.1f} GiB')")"
else
  # Measured: App Service Linux code deploys expose no cgroup limit. Without one the GC sizes
  # to the HOST VM, so an OOM says nothing about the 8 GiB SKU. An explicit
  # DOTNET_GCHeapHardLimit gives a deterministic ceiling, and makes the failure a dumpable
  # managed OutOfMemoryException rather than a kernel kill.
  hard=$(az webapp config appsettings list -g "$RG" -n "$app" \
         --query "[?name=='DOTNET_GCHeapHardLimit'].value" -o tsv 2>/dev/null)
  if [[ -n "$hard" ]]; then
    ck "GC heap ceiling configured" ok "no cgroup limit on this platform; DOTNET_GCHeapHardLimit=$hard"
  elif [[ "${ALLOW_NO_GC_LIMIT:-0}" == "1" ]]; then
    # Escape hatch for the phase-2 nolimit arms: what the GC does when nothing tells it about
    # the 8 GiB plan IS their question. Opt-in per arm, so the default stays a hard failure.
    # On a limit arm a missing limit is a dropped app setting or a restart that did not take.
    # The printed number is the payload: it is what separates the two phase-2 variants.
    avgb=$([[ -n "$av" ]] && python3 -c "print(f'{$av/1073741824:.1f} GiB')" || echo "unknown - /metrics/runtime did not report it")
    ck "GC heap ceiling configured" warn "no cgroup limit and no DOTNET_GCHeapHardLimit (ALLOW_NO_GC_LIMIT=1); GC believes it has $avgb"
  else
    ck "GC heap ceiling configured" no "no cgroup limit AND no DOTNET_GCHeapHardLimit - GC will size to the host"
  fi
fi

if [[ -n "$av" ]]; then
  gb=$(python3 -c "print(f'{$av/1073741824:.1f}')")
  # Should be ~75% of the cgroup limit, the documented default HeapHardLimitPercent.
  # Mode first, number second: on a P1v3 a nolimit arm's host-derived budget still lands under
  # 9 GiB, so a number-first chain would PASS "plan-sized ceiling" for an arm with no ceiling.
  if [[ "${ALLOW_NO_GC_LIMIT:-0}" == "1" ]]; then
    # Same escape, same reason. A warning rather than a pass because the number belongs in the
    # log: it is the measurement.
    ck "GC sees a plan-sized ceiling" warn "${gb} GiB - no hard limit set; this is the measurement the nolimit arm exists for"
  elif (( $(python3 -c "print(1 if $av < 9*1024**3 else 0)") )); then
    ck "GC sees a plan-sized ceiling" ok "${gb} GiB available to the GC"
  else
    ck "GC sees a plan-sized ceiling" no "${gb} GiB - GC is sizing to the host, not the 8 GiB plan"
  fi
fi

[[ "$cores" == "2" ]] && ck "worker has 2 vCPU" ok || ck "worker has 2 vCPU" no "reports $cores cores"

echo
echo "APS projection"
if [[ -f "$SECRETS/testconfig.json" ]]; then
python3 - "$SECRETS/testconfig.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
p = c["profiles"][c["profile"]]; q = len(c["arms"]); lim = c["temporal"]["apsLimit"]
if p.get("kind") == "burst":
    steady = peak = p["startsPerMinute"]/60*2*q
else:
    steady = p["targetOpenPerQueue"]*q/p["heartbeatIntervalSeconds"]
    peak = steady + p["startRatePerSecond"]*q
ok = peak <= lim*0.8
print(f"  {'\033[32mPASS\033[0m' if ok else '\033[31mFAIL\033[0m'} "
      f"{'profile '+c['profile']:<42} {steady:.1f} steady / {peak:.1f} peak vs {lim} limit")
sys.exit(0 if ok else 1)
PY
[[ $? -ne 0 ]] && fail=1
fi

echo
[[ $fail -eq 0 ]] && echo "All checks passed." || { echo "FAILURES above. Do not start a run."; exit 1; }
