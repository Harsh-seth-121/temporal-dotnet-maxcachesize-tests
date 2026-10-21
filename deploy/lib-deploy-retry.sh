# shellcheck shell=bash
# Retry a zip deploy.
#
# az webapp deploy intermittently returns a 502 gateway page from Kudu while the upload
# succeeds. Under set -e that kills the caller, orphaning an arm that is ramping fine. Three
# attempts, and a success check that asks the platform rather than trusting the exit status.
deploy_zip_with_retry() {
  local rg="$1" app="$2" zip="$3" attempt out
  for attempt in 1 2 3; do
    out=$(az webapp deploy --resource-group "$rg" --name "$app" \
            --src-path "$zip" --type zip --track-status false 2>&1) || true
    if grep -q '"complete": true' <<< "$out" \
       || grep -q "Deployment has completed successfully" <<< "$out"; then
      echo "  deployed to $app (attempt $attempt)"
      return 0
    fi
    echo "  deploy attempt $attempt to $app did not confirm; retrying" >&2
    sleep 20
    # The upload often lands despite the error page, so ask the platform directly.
    if az webapp deployment list -g "$rg" -n "$app" --query "[0].complete" -o tsv 2>/dev/null | grep -qi true; then
      echo "  platform reports the deployment completed; continuing"
      return 0
    fi
  done
  echo "  FATAL: $app did not deploy after 3 attempts" >&2
  return 1
}
