#!/usr/bin/env bash
# Publishes self-contained linux-x64 and deploys one identical binary to all four worker apps.
# The ONLY difference between arms is the MAX_CACHED_WORKFLOWS app setting.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
CFG="${SECRETS}/testconfig.json"
# One app. 60-run-arm.sh sets MAX_CACHED_WORKFLOWS per arm; this puts the binary and the
# settings common to every arm on the box.
INITIAL_CACHE="${INITIAL_CACHE:-10000}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ -f "$CFG" ]] || { echo "ERROR: $CFG missing. Copy config/testconfig.sample.json and fill it in."; exit 1; }
for f in client.pem client.key; do
  [[ -n "$(secret "$f" 2>/dev/null)" ]] || { echo "ERROR: certs/$f missing (gitignored; supply your own)."; exit 1; }
done

ADDRESS=$(python3 -c "import json;print(json.load(open('$CFG'))['temporal']['address'])")
NAMESPACE=$(python3 -c "import json;print(json.load(open('$CFG'))['temporal']['namespace'])")
case "$ADDRESS" in *"<namespace>"*) echo "ERROR: config still has placeholders."; exit 1;; esac

# Read straight from the gitignored files. Never pass PEM text as an argument: that puts the
# private key in shell history and the process table.
CERT_B64=$(base64 < "$(secret client.pem)" | tr -d '\n')
KEY_B64=$(base64  < "$(secret client.key)" | tr -d '\n')

TOKEN_FILE="$(secret metrics_token)"
if [[ ! -f "$TOKEN_FILE" ]]; then
  openssl rand -hex 32 > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  echo "generated $TOKEN_FILE"
fi
TOKEN=$(tr -d '\n' < "$TOKEN_FILE")

say "Publishing self-contained linux-x64"
# Self-contained pins the runtime into the artifact, so Azure cannot patch .NET under one arm
# and not another mid-experiment. All four arms get byte-identical bits.
rm -rf "$ROOT/publish/worker" "$ROOT/publish/worker.zip"
dotnet publish "$ROOT/src/CacheTest.Worker" -c Release -r linux-x64 --self-contained true \
  -o "$ROOT/publish/worker" --nologo -v q
# The config is not in the repo, so the csproj copy cannot pick it up. Stage it here. It
# carries the namespace handle but no key material: certs and tokens reach Azure as app
# settings, never as files in the zip.
mkdir -p "$ROOT/publish/worker/config"
cp "$SECRETS/testconfig.json" "$ROOT/publish/worker/config/testconfig.json"
# The wrapper captures the exit code, the only reliable way to tell a memory kill from a
# platform recycle. Copied in rather than published, so the .NET build stays byte-identical.
cp "$ROOT/deploy/start-worker.sh" "$ROOT/publish/worker/start-worker.sh"
chmod +x "$ROOT/publish/worker/start-worker.sh"
(cd "$ROOT/publish/worker" && zip -qr ../worker.zip .)
echo "  $(du -h "$ROOT/publish/worker.zip" | cut -f1) zip"

arm="c${INITIAL_CACHE}"; cache="$INITIAL_CACHE"; app="$WORKER_APP"
say "$app (initial cache=$cache)"

  # ALL settings before the deploy. Any app setting change restarts the app, so touching one
  # mid-run wipes that arm's cache.
  #
  # DOTNET_GCDynamicAdaptationMode=0 pins DATAS off. .NET 9+ enables it by default under Server
  # GC, where it resizes the heap in proportion to live data. Live data differs per arm BY
  # CONSTRUCTION here, so DATAS would adapt differently on every arm.
  #
  # WEBSITES_CONTAINER_STOP_TIME_LIMIT=120 against a 5s default and the worker's 20s
  # ShutdownTimeout. At the default every "graceful" stop is a SIGKILL at 5s, which reads the
  # same as an OOM kill.
  #
  # DOTNET_GCHeapHardLimit=0x1A0000000 is 6.5 GiB, hex because the env var takes hex. Measured:
  # App Service Linux code deploys expose NO cgroup memory limit, so without this the GC sizes
  # to the host VM rather than the 8 GiB plan and an OOM says nothing about the SKU.
  # It also buys a better failure mode: exceeding a GC hard limit raises a catchable managed
  # OutOfMemoryException with a crash dump, not a kernel SIGKILL with no evidence.
  # 6.5 of 8 GiB leaves 1.5 GiB for the runtime, the ASP.NET host, and the Temporal Rust core,
  # which allocates natively OUTSIDE this limit.
  az webapp config appsettings set --resource-group "$RG" --name "$app" --output none --settings \
    ARM="$arm" \
    MAX_CACHED_WORKFLOWS="$cache" \
    TASK_QUEUE="${PREFIX}-oom" \
    TEMPORAL_ADDRESS="$ADDRESS" \
    TEMPORAL_NAMESPACE="$NAMESPACE" \
    TEMPORAL_CLIENT_CERT_B64="$CERT_B64" \
    TEMPORAL_CLIENT_KEY_B64="$KEY_B64" \
    METRICS_BEARER_TOKEN="$TOKEN" \
    MAX_CONCURRENT_WORKFLOW_TASKS=200 \
    MAX_CONCURRENT_ACTIVITIES=400 \
    MAX_CONCURRENT_WORKFLOW_TASK_POLLS=10 \
    PROM_PORT=9100 \
    WEBSITE_TIME_ZONE=UTC \
    DOTNET_gcServer=1 \
    DOTNET_GCDynamicAdaptationMode=0 \
    WEBSITES_CONTAINER_STOP_TIME_LIMIT=120 \
    DOTNET_GCHeapHardLimit="${GC_HEAP_HARD_LIMIT:-0x1A0000000}"

  az webapp config set --resource-group "$RG" --name "$app" \
     --startup-file "./start-worker.sh" --output none

  # --track-status off: it polls "Starting the site..." for minutes after the site is serving.
  # 40-preflight.sh checks health properly, asserting each arm is OUR worker.
  # shellcheck source=lib-deploy-retry.sh
  . "$ROOT/deploy/lib-deploy-retry.sh"
  deploy_zip_with_retry "$RG" "$app" "$ROOT/publish/worker.zip"

say "Waiting for the worker to serve"
for i in $(seq 1 40); do
  body=$(curl -s --max-time 10 "https://${WORKER_APP}.azurewebsites.net/" 2>/dev/null || true)
  if [[ "$body" == arm=* ]]; then echo "  live: $body"; break; fi
  echo "  not yet"
  sleep 15
done

echo
echo "Deployed. Cache size is set per arm by deploy/60-run-arm.sh, which restarts the app"
echo "to clear the cache between arms. Run arms strictly one at a time:"
echo "  ./deploy/60-run-arm.sh 10000"
echo "  ./deploy/60-run-arm.sh 8000"
echo "  ./deploy/60-run-arm.sh 6000"
