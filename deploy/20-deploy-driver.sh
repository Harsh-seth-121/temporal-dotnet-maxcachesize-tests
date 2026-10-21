#!/usr/bin/env bash
# Deploys the load driver. Divergence detection scrapes the workers' public /metrics rather
# than Prometheus, which sits behind internal-only Container Apps ingress that an App Service
# app cannot reach without VNet integration.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
PROFILE="${PROFILE:-smoke}"
CFG="${SECRETS}/testconfig.json"
APP="$DRIVER_APP"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ -f "$CFG" ]] || { echo "ERROR: $CFG missing."; exit 1; }
ADDRESS=$(python3 -c "import json;print(json.load(open('$CFG'))['temporal']['address'])")
NAMESPACE=$(python3 -c "import json;print(json.load(open('$CFG'))['temporal']['namespace'])")
CERT_B64=$(base64 < "$(secret client.pem)" | tr -d '\n')
KEY_B64=$(base64  < "$(secret client.key)" | tr -d '\n')
TOKEN=$(tr -d '\n' < "$(secret metrics_token)")

# Separate token for the destructive control surface: read access to metrics is not the kill
# switch.
CONTROL_FILE="$(secret control_token)"
[[ -f "$CONTROL_FILE" ]] || { openssl rand -hex 32 > "$CONTROL_FILE"; chmod 600 "$CONTROL_FILE"; }
CONTROL=$(tr -d '\n' < "$CONTROL_FILE")

say "Publishing driver"
rm -rf "$ROOT/publish/driver" "$ROOT/publish/driver.zip"
dotnet publish "$ROOT/src/CacheTest.Driver" -c Release -r linux-x64 --self-contained true \
  -o "$ROOT/publish/driver" --nologo -v q
# The config is not in the repo, so the csproj copy cannot pick it up. Stage it here. It
# carries the namespace handle but no key material: certs and tokens reach Azure as app
# settings, never as files in the zip.
mkdir -p "$ROOT/publish/driver/config"
cp "$SECRETS/testconfig.json" "$ROOT/publish/driver/config/testconfig.json"
(cd "$ROOT/publish/driver" && zip -qr ../driver.zip .)

# Stop the app before changing anything. A deploy against a RUNNING driver restarts it, and a
# driver starting with PROFILE=oom begins a fresh ramp. Deploying the ramp fix once left 1,536
# unwanted workflows for the next arm to drain.
az webapp stop --resource-group "$RG" --name "$APP" --output none 2>/dev/null || true

say "Settings (profile=$PROFILE)"
az webapp config appsettings set --resource-group "$RG" --name "$APP" --output none --settings \
  PROFILE="$PROFILE" \
  CONFIG_PATH="config/testconfig.json" \
  TEMPORAL_ADDRESS="$ADDRESS" \
  TEMPORAL_NAMESPACE="$NAMESPACE" \
  TEMPORAL_CLIENT_CERT_B64="$CERT_B64" \
  TEMPORAL_CLIENT_KEY_B64="$KEY_B64" \
  METRICS_BEARER_TOKEN="$TOKEN" \
  CONTROL_BEARER_TOKEN="$CONTROL" \
  METRICS_URL_TEMPLATE="https://${PREFIX}-worker.azurewebsites.net" \
  RESIDENT_HORIZON_HOURS="${RESIDENT_HORIZON_HOURS:-12}" \
  START_CONCURRENCY="${START_CONCURRENCY:-16}" \
  DIVERGENCE_CHECK_EVERY="${DIVERGENCE_CHECK_EVERY:-60}" \
  WEBSITE_TIME_ZONE=UTC

az webapp config set --resource-group "$RG" --name "$APP" \
   --startup-file "./CacheTest.Driver" --output none
# shellcheck source=lib-deploy-retry.sh
. "$ROOT/deploy/lib-deploy-retry.sh"
deploy_zip_with_retry "$RG" "$APP" "$ROOT/publish/driver.zip"

say "Driver status"
sleep 25
curl -sf --max-time 30 "https://${APP}.azurewebsites.net/" | python3 -m json.tool || echo "not responding yet"
echo
echo "To end a run early:"
echo "  curl -X POST -H \"Authorization: Bearer \$(cat certs/control_token)\" \\"
echo "    https://${APP}.azurewebsites.net/release"
