#!/usr/bin/env bash
# Roll an in-progress rollover back by one stage. Never removes the old CA.
#
#   switched or verified  Point the role back at the old issuer. The new CA
#                         stays trusted, because leaves it
#                         signed may still be in use; the phase returns to
#                         trusted. Run again to remove that trust.
#   trusted               Remove the new CA from the Namespace's accepted CAs.
#                         Phase becomes rolled-back.
#   snapshot or
#   issuer-created        Nothing was changed outside Vault and the
#                         ConfigMap; phase becomes rolled-back.
#
# Refuses after retire: the old CA is already gone, so the way back is a new
# rollover.
#
# CHANGES VAULT (role issuer_ref) or TEMPORAL CLOUD (removes only the new
# CA), depending on the phase.
#
# Verify: the role and the accepted CAs match the state the rollback targets.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl jq tcld
resolve_target
use_ops_api_key

PROPAGATION_TIMEOUT="${PROPAGATION_TIMEOUT:-900}"

phase="$(state_get phase)"
issuer="$(state_get new_issuer)"
old_issuer="$(state_get old_issuer)"
new_fp="$(state_get new_ca_fingerprint)"

case "$phase" in
  switched|verified)
    [ -n "$old_issuer" ] || fail "no old issuer recorded in rotation-state"
    log "Pointing role $PKI_ROLE back at $old_issuer"
    vault_exec patch "$PKI_MOUNT/roles/$PKI_ROLE" issuer_ref="$old_issuer" >/dev/null
    [ "$(role_issuer)" = "$old_issuer" ] || fail "role $PKI_ROLE does not read back $old_issuer"
    log "PASS role $PKI_ROLE signs with $old_issuer"
    log "Leaves move back at the next ESO refresh; run ./scripts/force-refresh.sh to move them now."
    state_set phase trusted
    grafana_annotate "Rollback: proxies back on the old CA; $issuer still trusted"
    log "Phase is trusted. Run rollback.sh again to remove $issuer from the Namespace."
    ;;
  trusted)
    snapshot="$(state_get accepted_cas | tr ',' '\n' | sort)"
    if grep -qx "$new_fp" <<<"$snapshot"; then
      fail "$new_fp was already accepted at the Snapshot; not removing a CA this rollover did not add"
    fi
    if grep -qx "$new_fp" <<<"$(accepted_ca_fingerprints)"; then
      log "Removing new CA $issuer ($new_fp) from $TEMPORAL_NAMESPACE"
      tcld --auto_confirm namespace accepted-client-ca remove \
        -n "$TEMPORAL_NAMESPACE" \
        --ca-certificate-fingerprint "$new_fp" \
        --resource-version "$(tcld namespace get -n "$TEMPORAL_NAMESPACE" | jq -r '.resourceVersion')" \
        --request-id "rollback-ca-$issuer" >/dev/null
    fi
    deadline=$(( $(now_epoch) + PROPAGATION_TIMEOUT ))
    until [ "$(accepted_ca_fingerprints)" = "$snapshot" ]; do
      [ "$(now_epoch)" -lt "$deadline" ] || fail "accepted CAs never returned to the Snapshot: $(accepted_ca_fingerprints | paste -sd, -)"
      sleep 10
    done
    log "PASS accepted CAs equal the Snapshot ($(paste -sd, - <<<"$snapshot"))"
    state_set phase rolled-back
    grafana_annotate "Rollback: removed $issuer from $TEMPORAL_NAMESPACE"
    ;;
  snapshot|issuer-created)
    state_set phase rolled-back
    log "No trust or role change had been made; phase is rolled-back"
    ;;
  retired) fail "the old CA was already retired; start a new rollover instead" ;;
  *) fail "nothing to roll back (phase '${phase:-none}')" ;;
esac
