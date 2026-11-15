#!/usr/bin/env bash
# Rollover step 1: record the starting point in the rotation-state ConfigMap.
#
#   accepted_cas        Accepted client CA fingerprints (tcld, read only)
#   resource_version    The Namespace's resource version, for step 3
#   old_ca_fingerprint  The CA the proxies' current leaves chain to
#   leaf_source         manual (before migration) or vault
#   expected_proxies    Ready proxy replicas across client namespaces
#
# On the first run (migration) the old CA is the manually generated bootstrap
# CA. Afterwards it is the issuer the temporal-client role points at.
#
# Changes nothing outside the ConfigMap. Refuses to overwrite a snapshot
# while a rollover is in progress (phase set and not "retired").
#
# Verify: the old CA's fingerprint is among the accepted CAs.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl tcld jq openssl
resolve_target
use_ops_api_key

phase="$(state_get phase)"
case "$phase" in
  ""|retired) ;;
  *) fail "rollover in progress (phase=$phase); finish or roll back before taking a new snapshot" ;;
esac

leaf_source="$(state_get leaf_source)"
leaf_source="${leaf_source:-manual}"

if [ "$leaf_source" = "manual" ]; then
  require_demo_ca
  old_fp="$(cert_sha1 < "$MANUAL_CERT_FILE")"
  old_desc="manual bootstrap CA ($(basename "$MANUAL_CERT_FILE"))"
else
  issuer="$(vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" | jq -r '.data.issuer_ref')"
  old_fp="$(vault_exec read -format=json "$PKI_MOUNT/issuer/$issuer" | jq -r '.data.certificate' | cert_sha1)"
  old_desc="Vault issuer $issuer"
fi

accepted="$(accepted_ca_fingerprints)"
rv="$(tcld namespace get -n "$TEMPORAL_NAMESPACE" | jq -r '.resourceVersion')"

expected=0
for ns in "${CLIENT_NAMESPACES[@]}"; do
  ready="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.status.readyReplicas}')"
  expected=$((expected + ${ready:-0}))
done

grep -qx "$old_fp" <<<"$accepted" \
  || fail "the proxies' current CA ($old_desc, $old_fp) is not accepted by $TEMPORAL_NAMESPACE"

state_set accepted_cas "$(paste -sd, - <<<"$accepted")"
state_set resource_version "$rv"
state_set old_ca_fingerprint "$old_fp"
state_set leaf_source "$leaf_source"
state_set expected_proxies "$expected"
state_set snapshot_time "$(date -u +%FT%TZ)"
state_set phase snapshot

log "Snapshot recorded in $VAULT_NAMESPACE/configmap/$ROTATION_STATE_CONFIGMAP:"
log "  old CA:            $old_desc, $old_fp"
log "  accepted CAs:      $(paste -sd, - <<<"$accepted")"
log "  expected proxies:  $expected"
log "PASS the proxies' current CA is accepted by the Namespace"
