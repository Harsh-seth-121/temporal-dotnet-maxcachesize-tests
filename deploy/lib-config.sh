#!/usr/bin/env bash
# Single source of truth for every name the deploy scripts use. Sourced, not executed.
#
# Reads $SECRETS/harness.json, which ./deploy/setup.sh writes. Two files rather than one
# because deploy/10-deploy-workers.sh stages testconfig.json into the publish zip: the
# experiment definition ships to Azure, and the subscription id and resource group have no
# business on an App Service filesystem.
#
# Every value is exported ONLY IF UNSET, so `RG=other-group ./deploy/40-preflight.sh` keeps
# working exactly as it did when these were `${RG:-dev-success}` defaults.

# Sourcing, not running, so no `set -e` here: it would leak into the caller.

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Secrets live OUTSIDE the workspace. Gitignore stops a commit but not a shell command or an
# agent reading them, and a Bash deny-list is evaded by `cd certs && cat client.pem`.
SECRETS="${SECRETS_DIR:-$HOME/.config/temporal-cache-test}"
HARNESS="${HARNESS_FILE:-$SECRETS/harness.json}"

# deploy/62,63,66,68 use mapfile, which arrived in bash 4. macOS ships 3.2, so a stock-bash
# run silently collects nothing instead of failing. Fail here instead.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "FATAL: bash ${BASH_VERSION} is too old; deploy/62,63,66,68 need bash 4+." >&2
  echo "       macOS: brew install bash, then put its bin dir ahead of /bin on PATH." >&2
  return 1 2>/dev/null || exit 1
fi

if [ ! -f "$HARNESS" ]; then
  echo "FATAL: $HARNESS not found. Run ./deploy/setup.sh first." >&2
  return 1 2>/dev/null || exit 1
fi

# One python3 call for the whole block. The scripts already parse JSON this way for
# temporal.address, so this adds no dependency.
_cfg_eval=$(python3 - "$HARNESS" <<'PY'
import json, shlex, sys
a = json.load(open(sys.argv[1])).get("azure", {})
pairs = [
    ("AZURE_SUBSCRIPTION_ID", a.get("subscriptionId", "")),
    ("RG",             a.get("resourceGroup", "")),
    ("LOC",            a.get("location", "")),
    ("PREFIX",         a.get("prefix", "")),
    ("WORKER_SKU",     a.get("workerSku", "")),
    ("DRIVER_SKU",     a.get("driverSku", "")),
    ("RUNTIME",        a.get("runtime", "")),
    ("WORKERS",        a.get("workers", "")),
    ("OBS_STORAGE",    a.get("storageAccount", "")),
    ("DEPLOY_STORAGE", a.get("deployStorage", "")),
]
for name, value in pairs:
    print(f"_cfg_{name}={shlex.quote(str(value))}")
PY
) || { echo "FATAL: could not read $HARNESS" >&2; return 1 2>/dev/null || exit 1; }
eval "$_cfg_eval"
unset _cfg_eval

# Only-if-unset, so every existing env override survives.
: "${AZURE_SUBSCRIPTION_ID:=$_cfg_AZURE_SUBSCRIPTION_ID}"
: "${RG:=$_cfg_RG}"
: "${LOC:=$_cfg_LOC}"
: "${PREFIX:=$_cfg_PREFIX}"
: "${WORKER_SKU:=$_cfg_WORKER_SKU}"
: "${DRIVER_SKU:=$_cfg_DRIVER_SKU}"
: "${RUNTIME:=$_cfg_RUNTIME}"
: "${WORKERS:=$_cfg_WORKERS}"
: "${OBS_STORAGE:=$_cfg_OBS_STORAGE}"
: "${DEPLOY_STORAGE:=$_cfg_DEPLOY_STORAGE}"
unset "${!_cfg_@}"

if [ -z "$PREFIX" ] || [ "$PREFIX" = "temporal-cache-test" ]; then
  echo "FATAL: azure.prefix in $HARNESS is unset or still the shared default." >&2
  echo "       Azure web app names are globally unique. Run ./deploy/setup.sh --reset 4." >&2
  return 1 2>/dev/null || exit 1
fi

# Derived names, so no script spells them out twice.
WORKER_APP="${WORKER_APP:-${PREFIX}-worker}"
DRIVER_APP="${DRIVER_APP:-${PREFIX}-driver}"
WORKER_PLAN="${WORKER_PLAN:-${PREFIX}-plan}"
DRIVER_PLAN="${DRIVER_PLAN:-${PREFIX}-plan-drv}"
WORKER_URL="${WORKER_URL:-https://${WORKER_APP}.azurewebsites.net}"
DRIVER_URL="${DRIVER_URL:-https://${DRIVER_APP}.azurewebsites.net}"

# Run state: which arm is pending, launched or collected, and which worker app each one
# runs on. It lives beside the config rather than in docs/ because it is per-run state, not
# source: docs/ holds results, which are disposable output, and a clone that has never run
# has no state file to inherit. ./deploy/setup.sh writes the initial one.
# Exported, because lib-state-set.py and lib-state-summary.py are child processes.
export STATE="${STATE_FILE:-$SECRETS/run-state.json}"

# secret <filename> -> prints its path, preferring the out-of-tree copy
secret() {
  if [[ -f "$SECRETS/$1" ]]; then echo "$SECRETS/$1"
  elif [[ -f "$ROOT/certs/$1" ]]; then echo "$ROOT/certs/$1"
  else return 1; fi
}

# A subscription mismatch deploys the right zip into the wrong tenant and looks like success.
if [ -n "$AZURE_SUBSCRIPTION_ID" ] && [ "${SKIP_AZ_SUBSCRIPTION_CHECK:-0}" != "1" ]; then
  _cur=$(az account show --query id -o tsv 2>/dev/null)
  if [ -n "$_cur" ] && [ "$_cur" != "$AZURE_SUBSCRIPTION_ID" ]; then
    echo "  switching subscription: $_cur -> $AZURE_SUBSCRIPTION_ID" >&2
    az account set -s "$AZURE_SUBSCRIPTION_ID" 2>/dev/null \
      || echo "  WARNING: could not switch subscription" >&2
  fi
  unset _cur
fi
