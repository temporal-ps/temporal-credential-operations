#!/usr/bin/env bash
# Rollover step 0: confirm the starting point is healthy before changing
# anything. Read only: changes nothing in Vault, Kubernetes, or Temporal Cloud.
#
# Checks:
#   - Tools and .env.local inputs are present.
#   - The cluster, Vault, and the PKI role are reachable.
#   - The Namespace uses mTLS and accepts the CA the proxies' leaves chain to.
#   - Every proxy Deployment is Ready and every Ready proxy reports a loaded
#     leaf that is not about to expire.
#   - No TLS reload failures in the last 15 minutes.
#   - The current Vault issuer is not inside the rollover lead time.
#
# Verify: exits 0 only when every check prints PASS.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl jq openssl tcld temporal
resolve_target
use_ops_api_key

MIN_LEAF_REMAINING="${MIN_LEAF_REMAINING:-300}"   # seconds

kc get namespace "$VAULT_NAMESPACE" >/dev/null || fail "cluster $KUBE_CONTEXT is not reachable"
log "PASS cluster $KUBE_CONTEXT reachable"

leaf_source="$(state_get leaf_source)"
leaf_source="${leaf_source:-manual}"
phase="$(state_get phase)"
log "INFO leaf source: $leaf_source; rollover phase: ${phase:-none}"

vault_exec status >/dev/null || fail "Vault is not reachable or is sealed"
log "PASS Vault reachable and unsealed"

if [ "$leaf_source" = "manual" ]; then
  require_demo_ca
  current_fp="$(cert_sha1 < "$MANUAL_CERT_FILE")"
  current_desc="bootstrap CA"
else
  issuer="$(role_issuer)"
  [ -n "$issuer" ] && [ "$issuer" != "null" ] || fail "role $PKI_MOUNT/roles/$PKI_ROLE has no issuer"
  current_fp="$(issuer_cert "$issuer" | cert_sha1)"
  current_desc="Vault issuer $issuer"
  log "PASS role $PKI_ROLE signs with $issuer"
fi

ns_json="$(tcld namespace get -n "$TEMPORAL_NAMESPACE")"
auth="$(jq -r '.spec.authMethod // empty' <<<"$ns_json")"
case "$(tr 'A-Z' 'a-z' <<<"$auth")" in
  *mtls*) log "PASS $TEMPORAL_NAMESPACE uses mTLS authentication ($auth)" ;;
  *) fail "$TEMPORAL_NAMESPACE authentication is '${auth:-unknown}', expected mTLS" ;;
esac
accepted="$(accepted_ca_fingerprints)"
[ -n "$accepted" ] || fail "$TEMPORAL_NAMESPACE accepts no client CAs"
grep -qx "$current_fp" <<<"$accepted" \
  || fail "$TEMPORAL_NAMESPACE does not accept the $current_desc ($current_fp)"
log "PASS $TEMPORAL_NAMESPACE accepts the $current_desc ($current_fp); accepted: $(paste -sd, - <<<"$accepted")"

expected=0
for ns in "${CLIENT_NAMESPACES[@]}"; do
  ready="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.status.readyReplicas}')"
  want="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.spec.replicas}')"
  [ "${ready:-0}" = "$want" ] || fail "$ns/temporal-proxy ready ${ready:-0}/$want"
  expected=$((expected + want))
done
log "PASS every proxy Deployment Ready ($expected replicas)"

ready_pods="$(ready_proxy_pods | jq -R . | jq -sc .)"
series="$(prom_query 'tmprl_proxy_tls_cert_expiry_timestamp_seconds{file="cert"}' \
  | jq --argjson ready "$ready_pods" \
    '[.data.result[] | select(("\(.metric.namespace)/\(.metric.pod)") as $p | $ready | index($p))]')"
count="$(jq 'length' <<<"$series")"
[ "$count" -eq "$expected" ] || fail "$count of $expected Ready proxies report a loaded leaf"
log "PASS $count of $expected proxies report a loaded leaf"

short="$(jq -r --argjson min "$(( $(now_epoch) + MIN_LEAF_REMAINING ))" \
  '.[] | select((.value[1]|tonumber) < $min) | "\(.metric.namespace)/\(.metric.pod) NotAfter \(.value[1]|tonumber|floor|todate)"' <<<"$series")"
[ -z "$short" ] || fail "leaves expire within ${MIN_LEAF_REMAINING}s (ESO behind? run ./scripts/force-refresh.sh): $(paste -sd';' - <<<"$short")"
log "PASS every loaded leaf has more than ${MIN_LEAF_REMAINING}s left"

failures="$(prom_query 'sum(increase(tmprl_proxy_tls_reloads_total{result="failure"}[15m])) or vector(0)' \
  | jq -r '.data.result[0].value[1] | tonumber | floor')"
[ "$failures" = "0" ] || fail "$failures TLS reload failures in the last 15 minutes"
log "PASS no TLS reload failures in the last 15 minutes"

if [ "$leaf_source" = "vault" ]; then
  "$(dirname "${BASH_SOURCE[0]}")/../check-issuer-expiry.sh"
fi

log "Preflight passed."
