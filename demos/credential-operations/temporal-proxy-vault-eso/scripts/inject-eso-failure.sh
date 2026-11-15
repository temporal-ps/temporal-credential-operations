#!/usr/bin/env bash
# Failure injection: break leaf delivery in one client namespace, so the
# retirement gate has something to catch.
#
# Usage: ./scripts/inject-eso-failure.sh <workers|callers>            break
#        ./scripts/inject-eso-failure.sh <workers|callers> --restore  repair
#
# Breaking points the namespace's VaultDynamicSecret generator at a Vault
# Kubernetes auth role that does not exist. ESO's refreshes fail, the Secret
# keeps its last leaf, and the proxies keep presenting it until it expires
# (LEAF_TTL in demo-settings.env). Restoring re-applies the namespace's ESO
# resources and forces a refresh.
#
# CHANGES KUBERNETES only (one generator). Demo only.
#
# Verify: after breaking, the ExternalSecret reports Ready=False within one
# forced refresh; after restoring, it reports Ready=True and the Secret holds
# a new leaf.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq

ns="${1:-}"
case "$ns" in
  workers|callers) ;;
  *) fail "usage: $0 <workers|callers> [--restore]" ;;
esac

es_ready() {
  kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

annotate_sync() {
  kc -n "$ns" annotate externalsecret temporal-cloud-leaf --overwrite "force-sync=$(now_epoch)" >/dev/null
}

if [ "${2:-}" = "--restore" ]; then
  kc apply -k "$DEMO_DIR/k8s/eso-clients/$ns" >/dev/null
  kc -n "$ns" patch externalsecret temporal-cloud-leaf --type merge \
    -p "{\"spec\":{\"refreshInterval\":\"$ESO_REFRESH_INTERVAL\"}}" >/dev/null
  serial_before="$(kc -n "$ns" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)"
  annotate_sync
  deadline=$(( $(now_epoch) + 90 ))
  until [ "$(es_ready)" = "True" ] && \
        [ "$(kc -n "$ns" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)" != "$serial_before" ]; do
    [ "$(now_epoch)" -lt "$deadline" ] || fail "$ns: ExternalSecret did not recover"
    sleep 3
  done
  grafana_annotate "Failure injection repaired: $ns ESO delivery restored"
  log "PASS $ns: ExternalSecret Ready and a new leaf delivered"
  exit 0
fi

kc -n "$ns" patch vaultdynamicsecret temporal-cloud-leaf --type json \
  -p '[{"op":"replace","path":"/spec/provider/auth/kubernetes/role","value":"broken-by-failure-injection"}]' >/dev/null
annotate_sync
deadline=$(( $(now_epoch) + 90 ))
until [ "$(es_ready)" = "False" ]; do
  [ "$(now_epoch)" -lt "$deadline" ] || fail "$ns: ExternalSecret still Ready after breaking the generator"
  sleep 3
done
grafana_annotate "Failure injection: $ns ESO delivery broken"
log "PASS $ns: ExternalSecret Ready=False; its proxies keep their current leaf until it expires"
log "Repair with: $0 $ns --restore"
