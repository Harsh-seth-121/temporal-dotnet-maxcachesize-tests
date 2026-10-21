#!/usr/bin/env bash
# Deletes every resource this project created. App Service PLANS bill for allocated compute
# even when apps are stopped, so only deletion stops the meter.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
# Storage account names allow no hyphens, so the account does NOT match PREFIX and a
# prefix-only filter would orphan it. Named explicitly in harness.json.
SA="$OBS_STORAGE"

echo "Resources matching '${PREFIX}' in ${RG}:"
ids=$(az resource list -g "$RG" --query "[?starts_with(name,'${PREFIX}')].{n:name,t:type}" -o tsv)
echo "${ids:-  (none)}" | sed 's/^/  /'
if az storage account show -g "$RG" -n "$SA" --query name -o tsv >/dev/null 2>&1; then
  echo "  $SA	Microsoft.Storage/storageAccounts"
  HAVE_SA=1
else HAVE_SA=0; fi
if [[ -z "$ids" && "$HAVE_SA" == "0" ]]; then echo "nothing to delete"; exit 0; fi
echo
# The resource group may hold plans and apps belonging to other work, and the prefix filter
# is the only thing keeping them safe. Print the list and confirm before deleting. FORCE=1 skips the prompt
# for scripted runs; the prompt stays the default.
if [[ "${FORCE:-0}" == "1" ]]; then
  echo "FORCE=1, proceeding without confirmation"
else
  read -r -p "Delete ALL of the above? (type 'yes', or set FORCE=1 to skip) " ok
  [[ "$ok" == "yes" ]] || { echo "aborted"; exit 1; }
fi

# Apps before plans: deleting a plan with apps on it fails.
for t in "Microsoft.App/containerApps" "Microsoft.Web/sites" "Microsoft.App/managedEnvironments" "Microsoft.Web/serverFarms"; do
  for id in $(az resource list -g "$RG" --resource-type "$t" \
                --query "[?starts_with(name,'${PREFIX}')].id" -o tsv 2>/dev/null); do
    echo "deleting $(basename "$id")  [$t]"
    az resource delete --ids "$id" --output none || echo "  (failed, retry manually)"
  done
done
if [[ "$HAVE_SA" == "1" ]]; then
  echo "deleting $SA  [storage]"
  az storage account delete -g "$RG" -n "$SA" --yes --output none || echo "  (failed, retry manually)"
fi

cat <<'EOF'

Azure resources deleted. Two things remain, and neither is automatic:

1. Temporal Cloud: resident workflows may still be open and still firing heartbeat timers.
   Every timer is a billable Action.
     temporal workflow terminate \
       --query 'WorkflowType="ResidentWorkflow" AND ExecutionStatus="Running"' \
       --reason "cache test teardown"

2. REVOKE THE CERTIFICATE. The mTLS client cert was base64'd into App Service app settings and
   may persist in deployment history and activity logs. Deleting the apps does not revoke it.
   Rotate the namespace's client cert in the Temporal Cloud UI, then delete certs/ locally.
EOF
