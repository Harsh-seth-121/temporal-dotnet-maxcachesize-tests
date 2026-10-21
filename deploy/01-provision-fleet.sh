#!/usr/bin/env bash
# Provision the extra worker apps that let every arm run at once.
#
#   ./deploy/01-provision-fleet.sh            # workers 2..6, one plan each
#   WORKERS=3 ./deploy/01-provision-fleet.sh  # workers 2..3
#
# One plan per worker, not several apps on one plan: apps share their instance's 8 GiB, so two
# arms would compete for the memory being measured.
#
# Concurrent arms finish the set in ~90 minutes instead of nine hours, and every arm sees the
# same namespace conditions instead of being staggered across a day.
#
# Idempotent: an existing plan or app is left alone.
set -euo pipefail

# Names, SKU, runtime and the worker count come from harness.json, written by
# ./deploy/setup.sh. The runtime used to default to DOTNETCORE:9.0 here while
# 00-provision.sh hardcoded 10.0, so fleet workers 2..6 ran a .NET 9 runtime under a
# net10.0 app. One source now, so the two cannot drift again.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

exists() { az resource show -g "$RG" -n "$1" --resource-type "$2" --output none 2>/dev/null; }

say "Plans and apps for workers 2 to $WORKERS"
pids=()
for n in $(seq 2 "$WORKERS"); do
  (
    plan="${PREFIX}-plan-${n}"
    app="${PREFIX}-worker-${n}"

    if exists "$plan" "Microsoft.Web/serverfarms"; then
      echo "  plan $plan exists"
    else
      az appservice plan create -g "$RG" -n "$plan" -l "$LOC" --is-linux \
        --sku "$WORKER_SKU" --number-of-workers 1 --output none
      echo "  plan $plan created ($WORKER_SKU)"
    fi

    if exists "$app" "Microsoft.Web/sites"; then
      echo "  app $app exists"
    else
      az webapp create -g "$RG" --plan "$plan" -n "$app" --runtime "$RUNTIME" --output none
      # Always On: without it the app unloads after 20 idle minutes, taking the sticky cache
      # and that arm with it.
      az webapp config set -g "$RG" -n "$app" --always-on true --output none
      az webapp update -g "$RG" -n "$app" --https-only true --output none
      # Kudu and FTP default to internet-facing password auth into a shell on the box.
      for svc in scm ftp; do
        az resource update -g "$RG" -n "$svc" --namespace Microsoft.Web \
          --resource-type basicPublishingCredentialsPolicies --parent "sites/$app" \
          --set properties.allow=false --output none 2>/dev/null || true
      done
      # Single instance, no autoscale: scaling out splits one arm's population across caches.
      az webapp update -g "$RG" -n "$app" --client-affinity-enabled false --output none
      echo "  app $app created"
    fi
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

say "Fleet"
az webapp list -g "$RG" --query "[?starts_with(name,'${PREFIX}-worker')].{app:name,state:state}" -o table

cat <<MSG

  Next: deploy the worker build to every app, then run all arms at once.

      WORKERS=$WORKERS ./deploy/11-deploy-fleet.sh
      ./deploy/66-run-all.sh

  Cost note: each plan is a P1v3, roughly \$3.70/day, and bills whether its app runs or not.
  Delete the extra plans when the fleet is no longer needed.
MSG
