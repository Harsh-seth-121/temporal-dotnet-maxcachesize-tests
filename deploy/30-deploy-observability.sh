#!/usr/bin/env bash
# Prometheus + Grafana on Azure Container Apps, stock Docker Hub images. No container registry
# in this subscription, so config reaches them through Azure Files mounts, not a baked image.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
SA="$OBS_STORAGE"        # storage accounts: <=24 chars, lowercase alnum, no hyphens
ENVNAME="${PREFIX}-obs-env"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Extensions and providers"
az extension add --name containerapp --upgrade --only-show-errors --output none 2>/dev/null || true
az provider register --namespace Microsoft.App --wait --output none 2>/dev/null || true

say "Storage account + shares"
az storage account create -g "$RG" -n "$SA" -l "$LOC" --sku Standard_LRS \
  --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --output none
KEY=$(az storage account keys list -g "$RG" -n "$SA" --query "[0].value" -o tsv)
for share in promcfg promdata grafcfg grafdata; do
  az storage share create --account-name "$SA" --account-key "$KEY" --name "$share" \
     --quota 64 --output none
done

say "Uploading config"
TOKEN=$(tr -d '\n' < "$(secret metrics_token)")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
[[ -f "$ROOT/observability/prometheus.yml" ]] \
  || { echo "ERROR: observability/prometheus.yml is generated. Run ./deploy/setup.sh."; exit 1; }
cp "$ROOT/observability/prometheus.yml" "$TMP/prometheus.yml"
mkdir -p "$TMP/secrets"; printf '%s' "$TOKEN" > "$TMP/secrets/metrics_token"
az storage file upload-batch --account-name "$SA" --account-key "$KEY" \
   --destination promcfg --source "$TMP" --output none
az storage file upload-batch --account-name "$SA" --account-key "$KEY" \
   --destination grafcfg --source "$ROOT/observability/grafana" --output none

say "Container Apps environment"
# An interrupted create leaves the environment present but half-provisioned, and every later
# command fails with ManagedEnvironmentNotProvisioned. Anything not Succeeded is garbage:
# rebuild rather than report "(exists)" and fail downstream.
state=$(az containerapp env show -g "$RG" -n "$ENVNAME" --query properties.provisioningState -o tsv 2>/dev/null || echo "Absent")
if [[ "$state" != "Succeeded" && "$state" != "Absent" ]]; then
  echo "  environment is '$state', deleting and recreating"
  az containerapp env delete -g "$RG" -n "$ENVNAME" --yes --output none 2>/dev/null || true
  state="Absent"
fi
if [[ "$state" == "Absent" ]]; then
  az containerapp env create -g "$RG" -n "$ENVNAME" -l "$LOC" --logs-destination none --output none
  echo "  created"
else
  echo "  reusing (Succeeded)"
fi

for s in promcfg promdata grafcfg grafdata; do
  az containerapp env storage set -g "$RG" -n "$ENVNAME" --storage-name "$s" \
     --azure-file-account-name "$SA" --azure-file-account-key "$KEY" \
     --azure-file-share-name "$s" --access-mode ReadWrite --output none
done

# az containerapp create flags cannot express volume mounts, so both apps are defined in YAML.
say "Prometheus (internal ingress only)"
cat > "$TMP/prom.yaml" <<YAML
location: $LOC
properties:
  managedEnvironmentId: $(az containerapp env show -g "$RG" -n "$ENVNAME" --query id -o tsv)
  configuration:
    ingress:
      external: false
      targetPort: 9090
      transport: http
  template:
    containers:
      - name: prometheus
        image: docker.io/prom/prometheus:v3.6.0
        command: ["/bin/prometheus"]
        args:
          - "--config.file=/etc/prometheus/prometheus.yml"
          - "--storage.tsdb.path=/prometheus"
          - "--storage.tsdb.retention.time=30d"
        resources: { cpu: 1.0, memory: 2Gi }
        volumeMounts:
          - volumeName: promcfg
            mountPath: /etc/prometheus
          - volumeName: promdata
            mountPath: /prometheus
    scale: { minReplicas: 1, maxReplicas: 1 }
    volumes:
      - name: promcfg
        storageType: AzureFile
        storageName: promcfg
      - name: promdata
        storageType: AzureFile
        storageName: promdata
YAML
az containerapp create -g "$RG" -n "${PREFIX}-prom" --yaml "$TMP/prom.yaml" --output none \
  || az containerapp update -g "$RG" -n "${PREFIX}-prom" --yaml "$TMP/prom.yaml" --output none

say "Grafana (external ingress, admin password)"
GF_FILE="$SECRETS/grafana_admin_password"
[[ -f "$GF_FILE" ]] || { openssl rand -base64 24 | tr -d '\n' > "$GF_FILE"; chmod 600 "$GF_FILE"; }
GF_PW=$(cat "$GF_FILE")
cat > "$TMP/graf.yaml" <<YAML
location: $LOC
properties:
  managedEnvironmentId: $(az containerapp env show -g "$RG" -n "$ENVNAME" --query id -o tsv)
  configuration:
    secrets:
      - name: admin-password
        value: "$GF_PW"
    ingress:
      external: true
      targetPort: 3000
      transport: auto
  template:
    containers:
      - name: grafana
        image: docker.io/grafana/grafana:12.2.0
        env:
          - name: GF_SECURITY_ADMIN_PASSWORD
            secretRef: admin-password
          - name: GF_AUTH_ANONYMOUS_ENABLED
            value: "false"
          - name: GF_USERS_ALLOW_SIGN_UP
            value: "false"
          - name: GF_USERS_DEFAULT_THEME
            value: "dark"
        resources: { cpu: 0.5, memory: 1Gi }
        volumeMounts:
          - volumeName: grafcfg
            mountPath: /etc/grafana/provisioning
            subPath: provisioning
          - volumeName: grafcfg
            mountPath: /etc/grafana/dashboards
            subPath: dashboards
          - volumeName: grafdata
            mountPath: /var/lib/grafana
    scale: { minReplicas: 1, maxReplicas: 1 }
    volumes:
      - name: grafcfg
        storageType: AzureFile
        storageName: grafcfg
      - name: grafdata
        storageType: AzureFile
        storageName: grafdata
YAML
az containerapp create -g "$RG" -n "${PREFIX}-grafana" --yaml "$TMP/graf.yaml" --output none \
  || az containerapp update -g "$RG" -n "${PREFIX}-grafana" --yaml "$TMP/graf.yaml" --output none

say "Done"
echo "Grafana: https://$(az containerapp show -g "$RG" -n "${PREFIX}-grafana" --query properties.configuration.ingress.fqdn -o tsv)"
echo "  user: admin"
echo "  pass: cat certs/grafana_admin_password"
