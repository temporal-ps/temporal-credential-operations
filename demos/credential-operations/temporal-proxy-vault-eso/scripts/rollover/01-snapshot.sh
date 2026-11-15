#!/usr/bin/env bash
# Rollover step 1: record the starting point in the rotation-state ConfigMap.
#
#   accepted_cas        Accepted client CA fingerprints (tcld, read only)
#   resource_version    The Namespace's resource version, for step 3
#   old_ca_fingerprint  The CA the proxies' current leaves chain to
#   old_issuer          The Vault issuer behind it: the one the temporal-client
#                       role points at
#   expected_proxies    Ready proxy replicas across client namespaces
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
  ""|retired|rolled-back) ;;
  *) fail "rollover in progress (phase=$phase); finish or roll back before taking a new snapshot" ;;
esac

old_issuer="$(role_issuer)"
old_fp="$(issuer_cert "$old_issuer" | cert_sha1)"
old_desc="Vault issuer $old_issuer"

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
state_set old_issuer "$old_issuer"
state_set expected_proxies "$expected"
state_set snapshot_time "$(date -u +%FT%TZ)"
state_set phase snapshot

log "Snapshot recorded in $VAULT_NAMESPACE/configmap/$ROTATION_STATE_CONFIGMAP:"
log "  old CA:            $old_desc, $old_fp"
log "  accepted CAs:      $(paste -sd, - <<<"$accepted")"
log "  expected proxies:  $expected"
log "PASS the proxies' current CA is accepted by the Namespace"
