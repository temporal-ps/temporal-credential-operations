#!/usr/bin/env bash
# Milestone 1: create the k3d cluster, import the proxy image, and deploy a
# Temporal Proxy plus CLI probe in each client namespace, with Prometheus and
# Grafana. The proxies present the manually generated bootstrap material.
#
# Idempotent: re-running converges on the same state.
#
# Verify: ./scripts/verify-m1.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools docker k3d kubectl openssl
resolve_target

if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "Cluster $CLUSTER_NAME exists"
else
  k3d cluster create --config "$DEMO_DIR/k3d/cluster.yaml"
fi
kc wait --for=condition=Ready node --all --timeout=120s

docker image inspect "$TEMPORAL_PROXY_IMAGE" >/dev/null 2>&1 \
  || fail "image $TEMPORAL_PROXY_IMAGE not found; run ./scripts/build-proxy-image.sh"
k3d image import "$TEMPORAL_PROXY_IMAGE" --cluster "$CLUSTER_NAME"

kc apply -f "$DEMO_DIR/k8s/namespaces.yaml"

# Non-secret target settings, kept out of committed manifests.
for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc -n "$ns" create configmap temporal-cloud-target \
    --from-literal=TEMPORAL_CLOUD_ENDPOINT="$TEMPORAL_CLOUD_ENDPOINT" \
    --from-literal=TEMPORAL_NAMESPACE="$TEMPORAL_NAMESPACE" \
    --dry-run=client -o yaml | kc apply -f -
done

"$DEMO_DIR/scripts/bootstrap-manual.sh"

# Grafana admin password: generated once, never printed.
if ! kc -n "$OBSERVABILITY_NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
  kc -n "$OBSERVABILITY_NAMESPACE" create secret generic grafana-admin \
    --from-literal=password="$(openssl rand -hex 16)" >/dev/null
fi

kc apply -k "$DEMO_DIR/k8s/observability"
# After the migration switch, keep the proxies on the ESO-managed Secret.
clients_dir="clients"
[ "$(state_get leaf_source)" != "vault" ] || clients_dir="clients-vault"
for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc apply -k "$DEMO_DIR/k8s/$clients_dir/$ns"
done

for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc -n "$ns" rollout status deploy/temporal-proxy --timeout=180s
  kc -n "$ns" rollout status deploy/cli-probe --timeout=180s
done
kc -n "$OBSERVABILITY_NAMESPACE" rollout status deploy/prometheus --timeout=180s
kc -n "$OBSERVABILITY_NAMESPACE" rollout status deploy/grafana --timeout=180s

"$DEMO_DIR/scripts/apply-settings.sh"

log "Up. Next: ./scripts/verify-m1.sh, then ./scripts/observe.sh for Grafana."
