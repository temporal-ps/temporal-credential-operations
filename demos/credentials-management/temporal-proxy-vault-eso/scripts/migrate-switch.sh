#!/usr/bin/env bash
# Migration form of rollover step 4, run once: move the proxies from the manual
# bootstrap Secret to the ESO-managed Secret temporal-cloud-leaf.
#
#   1. Refuse unless step 3 verified the Namespace accepts the new issuer.
#   2. Apply the ESO generator and ExternalSecret in each client namespace and
#      wait until the Secret holds a leaf signed by the new issuer.
#   3. Repoint each proxy Deployment at temporal-cloud-leaf. This is the only
#      Pod restart in the design. A new Pod that cannot connect does not become
#      Ready, so the rollout stalls with the old Pods still serving.
#
# Idempotent.
#
# Verify: ./scripts/verify-m2.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl

phase="$(state_get phase)"
[ "$(state_get leaf_source)" = "manual" ] || [ "$phase" = "switched" ] \
  || fail "leaf source is already $(state_get leaf_source); this script is for the first migration only"
case "$phase" in
  trusted|switched) ;;
  *) fail "expected phase trusted, found '${phase:-none}'; run rollover steps 1 to 3 first" ;;
esac

issuer="$(state_get new_issuer)"
pem="$STATE_DIR/$issuer.pem"
[ -f "$pem" ] || fail "missing $pem"

for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc apply -k "$DEMO_DIR/k8s/eso-clients/$ns" >/dev/null
  kc -n "$ns" wait --for=condition=Ready externalsecret/temporal-cloud-leaf --timeout=120s >/dev/null \
    || { kc -n "$ns" describe externalsecret temporal-cloud-leaf | tail -15 >&2; fail "$ns: ExternalSecret not Ready"; }
  crt="$(kc -n "$ns" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' | base64 -d)"
  openssl verify -CAfile "$pem" <(printf '%s\n' "$crt") >/dev/null 2>&1 \
    || fail "$ns: Secret temporal-cloud-leaf is not signed by $issuer"
  log "PASS $ns: temporal-cloud-leaf holds a leaf signed by $issuer"
  printf '%s\n' "$crt" | openssl x509 -noout -subject -enddate | sed 's/^/  /'
done

switch_time="$(state_get switch_time)"
[ -n "$switch_time" ] || switch_time="$(date -u +%FT%TZ)"
for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc apply -k "$DEMO_DIR/k8s/clients-vault/$ns" >/dev/null
done
for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc -n "$ns" rollout status deploy/temporal-proxy --timeout=300s
done

state_set switch_time "$switch_time"
state_set switch_epoch "$(date -j -u -f %FT%TZ "$switch_time" +%s 2>/dev/null || date -u -d "$switch_time" +%s)"
state_set leaf_source vault
state_set phase switched
log "Switched at $switch_time. Next: ./scripts/verify-m2.sh"
