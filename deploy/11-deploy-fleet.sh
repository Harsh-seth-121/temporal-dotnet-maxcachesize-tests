#!/usr/bin/env bash
# Deploy the worker build to every app in the fleet, in parallel.
#
#   ./deploy/11-deploy-fleet.sh            # workers 1..6
#   WORKERS=3 ./deploy/11-deploy-fleet.sh  # workers 1..3
#
# Publishes once and uploads one zip to every app. Rebuilding per app would make "which build
# was this" a variable across arms.
#
# Per-arm settings (cache size, GC mode, task queue) belong to 66-run-all.sh: changing an app
# setting restarts the app, which must happen at arm start, not deploy time.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

ADDRESS=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['address'])")
NAMESPACE=$(python3 -c "import json;print(json.load(open('$SECRETS/testconfig.json'))['temporal']['namespace'])")
CERT_B64=$(base64 < "$SECRETS/client.pem" | tr -d '\n')
KEY_B64=$(base64 < "$SECRETS/client.key" | tr -d '\n')
TOKEN=$(tr -d '\n' < "$SECRETS/metrics_token")

say "Publishing worker"
rm -rf "$ROOT/publish/worker" "$ROOT/publish/worker.zip"
dotnet publish "$ROOT/src/CacheTest.Worker" -c Release -r linux-x64 --self-contained true \
  -o "$ROOT/publish/worker" --nologo -v q
mkdir -p "$ROOT/publish/worker/config"
cp "$SECRETS/testconfig.json" "$ROOT/publish/worker/config/testconfig.json"
cp "$ROOT/deploy/start-worker.sh" "$ROOT/publish/worker/start-worker.sh"
chmod +x "$ROOT/publish/worker/start-worker.sh"
(cd "$ROOT/publish/worker" && zip -qr ../worker.zip .)
echo "  $(du -h "$ROOT/publish/worker.zip" | cut -f1) zip"

say "Staging the zip in blob storage"
# Uploading from here to each app fails: Kudu answers 400 BadRequest for the 58 MB package on
# the newer apps while accepting a 174-byte one, and five concurrent uploads reset the
# connection. Stage once, let each app pull server-side.
SA="$DEPLOY_STORAGE"
KEY=$(az storage account keys list -g "$RG" -n "$SA" --query "[0].value" -o tsv)
az storage container create --account-name "$SA" --account-key "$KEY" -n deploy --output none
for attempt in 1 2 3; do
  if az storage blob upload --account-name "$SA" --account-key "$KEY" -c deploy -n worker.zip \
       -f "$ROOT/publish/worker.zip" --overwrite --max-connections 2 --output none; then
    break
  fi
  echo "  upload attempt $attempt was reset; retrying" >&2
  [ "$attempt" = 3 ] && { echo "FATAL: could not stage the zip" >&2; exit 1; }
done
# Must match what was just uploaded. A stale blob deploys yesterday's binary.
_local=$(wc -c < "$ROOT/publish/worker.zip" | tr -d ' ')
_remote=$(az storage blob show --account-name "$SA" --account-key "$KEY" -c deploy -n worker.zip \
          --query "properties.contentLength" -o tsv)
[ "$_local" = "$_remote" ] || { echo "FATAL: staged $_remote bytes, local is $_local" >&2; exit 1; }
EXPIRY=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.UTC)+datetime.timedelta(hours=8)).strftime('%Y-%m-%dT%H:%MZ'))")
SAS=$(az storage blob generate-sas --account-name "$SA" --account-key "$KEY" -c deploy \
      -n worker.zip --permissions r --expiry "$EXPIRY" --https-only -o tsv)
ZIP_URL="https://${SA}.blob.core.windows.net/deploy/worker.zip?${SAS}"
echo "  staged $_remote bytes, SAS good for 8 hours"

app_name() { [ "$1" = 1 ] && echo "${PREFIX}-worker" || echo "${PREFIX}-worker-$1"; }

say "Deploying to $WORKERS workers in parallel"
pids=()
for n in $(seq 1 "$WORKERS"); do
  app=$(app_name "$n")
  (
    # Identical on every worker. Per-arm settings come later.
    az webapp config appsettings set -g "$RG" -n "$app" --output none --settings \
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
      WEBSITES_CONTAINER_STOP_TIME_LIMIT=120
    az webapp config set -g "$RG" -n "$app" --startup-file "./start-worker.sh" --output none
    az webapp deploy -g "$RG" -n "$app" --src-url "$ZIP_URL" --type zip --track-status false
    echo "  $app accepted the package"
  ) > "${TMPDIR:-/tmp}/fleet-deploy-$n.log" 2>&1 &
  pids+=($!)
done

fail=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "  worker $((i+1)) deployed"
  else
    echo "  worker $((i+1)) FAILED, see /tmp/fleet-deploy-$((i+1)).log" >&2
    fail=1
  fi
done
[ "$fail" = 1 ] && { echo "At least one deploy failed; fix before running arms." >&2; exit 1; }

say "Fleet deployed"
echo "  Next: ./deploy/66-run-all.sh"
