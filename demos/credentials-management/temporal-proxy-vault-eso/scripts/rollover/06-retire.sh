#!/usr/bin/env bash
# Rollover step 6: retire the old CA.
#
# CHANGES TEMPORAL CLOUD: removes the Snapshot's old CA from the Namespace's
# accepted client CAs. It is the only CA any script removes, and only after
# the gate passes again here. CHANGES VAULT: if the old CA is a Vault issuer,
# sets its usage to read-only,crl-signing so it can no longer sign leaves
# (kept, not deleted, for audit and rollback).
#
# Refuses unless step 5 passed, and refuses if the accepted CAs differ from
# Snapshot + new (a concurrent change must be reviewed first).
#
# Idempotent: skips the removal if the old CA is already gone.
#
# Verify:
#   1. Accepted CAs equal Snapshot - old + new.
#   2. The old Vault issuer refuses to sign (skipped for the manual CA).
#   3. Probes keep succeeding for PROBE_SECONDS after the removal.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl tcld jq openssl
resolve_target
use_ops_api_key

PROPAGATION_TIMEOUT="${PROPAGATION_TIMEOUT:-900}"   # seconds
PROBE_SECONDS="${PROBE_SECONDS:-90}"

phase="$(state_get phase)"
case "$phase" in
  verified|retired) ;;
  *) fail "expected phase verified (run 05-verify.sh), found '${phase:-none}'" ;;
esac

old_fp="$(state_get old_ca_fingerprint)"
new_fp="$(state_get new_ca_fingerprint)"
old_issuer="$(state_get old_issuer)"
snapshot="$(state_get accepted_cas | tr ',' '\n' | sort)"
before="$(printf '%s\n%s\n' "$snapshot" "$new_fp" | grep -v '^$' | sort -u)"
after="$(printf '%s\n' "$before" | grep -vx "$old_fp" | sort -u)"
[ -n "$after" ] || fail "retiring $old_fp would leave the Namespace with no accepted CA"

log "Re-evaluating the gate before removing trust"
out="$(gate_evaluate)" || { printf '%s\n' "$out"; fail "gate does not pass; nothing removed"; }
printf '%s\n' "$out"

ns_json="$(tcld namespace get -n "$TEMPORAL_NAMESPACE")"
current="$(accepted_ca_fingerprints)"
if [ "$current" = "$after" ]; then
  log "$old_fp already removed from $TEMPORAL_NAMESPACE; skipping removal"
else
  [ "$current" = "$before" ] \
    || fail "accepted CAs are not Snapshot + new; review before retiring: $(paste -sd, - <<<"$current")"
  log "Removing old CA $old_fp from $TEMPORAL_NAMESPACE accepted client CAs"
  tcld --auto_confirm namespace accepted-client-ca remove \
    -n "$TEMPORAL_NAMESPACE" \
    --ca-certificate-fingerprint "$old_fp" \
    --resource-version "$(jq -r '.resourceVersion' <<<"$ns_json")" \
    --request-id "remove-ca-$old_fp-$(state_get new_issuer)" >/dev/null
  grafana_annotate "Retire: removed CA $old_fp from $TEMPORAL_NAMESPACE"
fi
removed_at="$(date -u +%FT%TZ)"

deadline=$(( $(now_epoch) + PROPAGATION_TIMEOUT ))
until [ "$(accepted_ca_fingerprints)" = "$after" ]; do
  [ "$(now_epoch)" -lt "$deadline" ] || fail "accepted CAs never matched Snapshot - old + new: $(accepted_ca_fingerprints | paste -sd, -)"
  sleep 10
done
log "PASS accepted CAs = Snapshot - old + new ($(paste -sd, - <<<"$after"))"

if [ -n "$old_issuer" ]; then
  vault_exec patch "$PKI_MOUNT/issuer/$old_issuer" usage=read-only,crl-signing >/dev/null
  if vault_exec write -format=json "$PKI_MOUNT/issuer/$old_issuer/issue/$PKI_ROLE" \
       common_name=workers.temporal-proxy ttl=1m >/dev/null 2>&1; then
    fail "old issuer $old_issuer still signs leaves"
  fi
  log "PASS old issuer $old_issuer refuses to sign (usage read-only,crl-signing)"
else
  log "INFO old CA was the manual bootstrap CA; nothing to disable in Vault"
fi

log "Watching probes for ${PROBE_SECONDS}s after the removal"
sleep "$PROBE_SECONDS"
for ns in "${CLIENT_NAMESPACES[@]}"; do
  logs="$(kc -n "$ns" logs deploy/cli-probe --since-time="$removed_at")"
  ok="$(grep -c ' ok ' <<<"$logs" || true)"
  bad="$(grep -c ' FAIL ' <<<"$logs" || true)"
  [ "$ok" -gt 0 ] || fail "$ns: no successful probe calls since the removal"
  [ "$bad" -eq 0 ] || { grep ' FAIL ' <<<"$logs" | tail -3 >&2; fail "$ns: $bad failed probe calls since the removal"; }
  log "PASS $ns: $ok probe calls since the removal, 0 failed"
done

state_set phase retired
state_set retire_time "$removed_at"
log "Rollover complete: $TEMPORAL_NAMESPACE trusts $(paste -sd, - <<<"$after")"
