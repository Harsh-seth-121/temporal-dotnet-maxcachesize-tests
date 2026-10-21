#!/usr/bin/env bash
# Creates every Azure resource for the MaxCachedWorkflows experiment. Idempotent. Nothing
# outside the configured resource group, every resource carrying the configured prefix so
# teardown can filter precisely.
set -euo pipefail

# Resource group, location, prefix, SKUs and runtime all come from harness.json, written by
# ./deploy/setup.sh. The default SKU is P1V3: 2 vCPU / 8 GiB exactly. 8 and not 16, because
# P1MV3 doubles the headroom and nothing reaches OOM.
#
# ONE worker app, reconfigured between arms. Identical hardware removes the confound the
# previous report flagged, where cache size was inseparable from which VM it landed on.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Subscription"
az account show --query "{name:name, id:id}" -o tsv

# Plans FIRST, on their own. A quota refusal is the likeliest failure; this way it costs one
# failed command.
say "App Service plans (quota check happens here)"
az appservice plan create \
  --resource-group "$RG" --name "$WORKER_PLAN" \
  --location "$LOC" --is-linux --sku "$WORKER_SKU" --number-of-workers 1 \
  --output none
echo "  plan $WORKER_PLAN ($WORKER_SKU)"
az appservice plan create \
  --resource-group "$RG" --name "$DRIVER_PLAN" \
  --location "$LOC" --is-linux --sku "$DRIVER_SKU" --number-of-workers 1 --output none
echo "  plan $DRIVER_PLAN ($DRIVER_SKU)"

say "Web apps"
create_app() {
  local name="$1" plan="$2"
  az webapp create --resource-group "$RG" --plan "$plan" --name "$name" \
     --runtime "$RUNTIME" --output none

  # Always On: without it the app unloads after 20 idle minutes, taking the sticky cache
  # with it.
  az webapp config set --resource-group "$RG" --name "$name" --always-on true --output none

  # The bearer token on /metrics is worthless if the request can arrive over cleartext.
  az webapp update --resource-group "$RG" --name "$name" --https-only true --output none

  # Kudu/SCM and FTP default to internet-facing password auth into a shell on the box.
  # Unused here: deployment goes through az with AAD.
  az resource update \
    --resource-group "$RG" --name scm --namespace Microsoft.Web \
    --resource-type basicPublishingCredentialsPolicies --parent "sites/$name" \
    --set properties.allow=false --output none 2>/dev/null || echo "    (scm basic-auth policy unavailable, check manually)"
  az resource update \
    --resource-group "$RG" --name ftp --namespace Microsoft.Web \
    --resource-type basicPublishingCredentialsPolicies --parent "sites/$name" \
    --set properties.allow=false --output none 2>/dev/null || echo "    (ftp basic-auth policy unavailable, check manually)"

  # Single instance, no autoscale: scaling out splits the population across caches.
  az webapp update --resource-group "$RG" --name "$name" --client-affinity-enabled false --output none
  echo "  app $name"
}
create_app "$WORKER_APP" "$WORKER_PLAN"
create_app "$DRIVER_APP" "$DRIVER_PLAN"

say "Logging to filesystem (so az webapp log tail works)"
az webapp log config --resource-group "$RG" --name "$WORKER_APP" \
   --docker-container-logging filesystem --application-logging filesystem \
   --level information --output none
az webapp log config --resource-group "$RG" --name "$DRIVER_APP" \
   --docker-container-logging filesystem --application-logging filesystem \
   --level information --output none

say "Done. Next: deploy/10-deploy-workers.sh"
