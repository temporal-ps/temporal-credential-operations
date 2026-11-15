#!/usr/bin/env bash
# Milestone 2: install Vault (dev mode) and External Secrets Operator (ESO) from
# pinned Helm charts, then configure Vault for the demo:
#
#   - PKI secrets engine at pki-temporal (no issuer yet; 02-create-issuer.sh
#     creates issuers and, on the first run, the temporal-client role).
#   - Policy temporal-client-issue: only "update" on
#     pki-temporal/issue/temporal-client.
#   - Kubernetes auth with one role per client namespace (<ns>-pki), bound to
#     that namespace's vault-pki-client service account.
#
# Changes nothing in the proxies or in Temporal Cloud. Idempotent.
#
# Verify: the script ends by logging in to Vault as each namespace's service
# account and checking that the token carries only the issue policy.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl helm jq

kc apply -f "$DEMO_DIR/k8s/namespaces.yaml" >/dev/null

helm upgrade --install vault vault \
  --kube-context "$KUBE_CONTEXT" --namespace "$VAULT_NAMESPACE" \
  --repo "$VAULT_CHART_REPO" --version "$VAULT_CHART_VERSION" \
  --values "$DEMO_DIR/helm/vault-values.yaml" --wait --timeout 5m

helm upgrade --install external-secrets external-secrets \
  --kube-context "$KUBE_CONTEXT" --namespace "$ESO_NAMESPACE" \
  --repo "$ESO_CHART_REPO" --version "$ESO_CHART_VERSION" \
  --values "$DEMO_DIR/helm/external-secrets-values.yaml" --wait --timeout 5m

kc -n "$VAULT_NAMESPACE" wait --for=condition=Ready pod/vault-0 --timeout=120s

# PKI mount. Issuers are created by 02-create-issuer.sh.
if ! vault_exec secrets list -format=json | jq -e --arg m "$PKI_MOUNT/" 'has($m)' >/dev/null; then
  vault_exec secrets enable -path="$PKI_MOUNT" pki >/dev/null
  log "Enabled PKI secrets engine at $PKI_MOUNT"
fi
vault_exec secrets tune -max-lease-ttl=87600h "$PKI_MOUNT" >/dev/null

# Policy: issue leaves from the one role, nothing else.
kc -n "$VAULT_NAMESPACE" exec -i vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault policy write temporal-client-issue - >/dev/null <<EOF
path "$PKI_MOUNT/issue/$PKI_ROLE" {
  capabilities = ["update"]
}
EOF

# Kubernetes auth. Vault runs in the cluster, so it reviews tokens with its own
# service account (bound to system:auth-delegator by the chart).
if ! vault_exec auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  vault_exec auth enable kubernetes >/dev/null
  log "Enabled Kubernetes auth"
fi
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" >/dev/null

for ns in "${CLIENT_NAMESPACES[@]}"; do
  vault_exec write "auth/kubernetes/role/$ns-pki" \
    bound_service_account_names=vault-pki-client \
    bound_service_account_namespaces="$ns" \
    audience=vault \
    token_policies=temporal-client-issue \
    token_ttl=5m token_max_ttl=5m >/dev/null
  kc -n "$ns" apply -f "$DEMO_DIR/k8s/eso/serviceaccount.yaml" >/dev/null
  log "Vault role $ns-pki bound to $ns/vault-pki-client"
done

# Verify: each namespace's identity logs in and gets only the issue policy.
for ns in "${CLIENT_NAMESPACES[@]}"; do
  jwt="$(kc -n "$ns" create token vault-pki-client --audience vault --duration 10m)"
  policies="$(vault_exec write -format=json auth/kubernetes/login role="$ns-pki" jwt="$jwt" \
    | jq -r '.auth.token_policies | join(",")')"
  [ "$policies" = "default,temporal-client-issue" ] \
    || fail "$ns: Vault login returned policies '$policies'"
  log "PASS $ns: vault-pki-client logs in to Vault with policies $policies"
done

"$DEMO_DIR/scripts/apply-settings.sh"

log "Vault and ESO ready. Next: ./scripts/rollover/01-snapshot.sh"
