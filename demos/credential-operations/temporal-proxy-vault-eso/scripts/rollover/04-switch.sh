#!/usr/bin/env bash
# Rollover step 4: point the temporal-client role at the new issuer. From the
# next ESO refresh on, every leaf Vault signs chains to the new CA.
#
# CHANGES VAULT: the role's issuer_ref. Nothing else in the role changes
# (vault patch). No Pod restarts and no Temporal Cloud change.
#
# Refuses unless step 3 verified the new CA in the Namespace.
#
# Idempotent: re-running after success re-verifies and changes nothing.
#
# Verify: the role reads back the new issuer, and the switch time is recorded.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl jq

issuer="$(state_get new_issuer)"
phase="$(state_get phase)"
case "$phase" in
  trusted) ;;
  switched|verified)
    [ "$(role_issuer)" = "$issuer" ] || fail "phase is $phase but the role does not point at $issuer"
    log "Already switched to $issuer at $(state_get switch_time); nothing to do"
    exit 0 ;;
  *) fail "expected phase trusted (run 03-add-trust.sh), found '${phase:-none}'" ;;
esac

old="$(role_issuer)"
log "Switching role $PKI_ROLE from $old to $issuer"
vault_exec patch "$PKI_MOUNT/roles/$PKI_ROLE" issuer_ref="$issuer" >/dev/null

[ "$(role_issuer)" = "$issuer" ] || fail "role $PKI_ROLE does not read back $issuer"
state_set switch_time "$(date -u +%FT%TZ)"
state_set switch_epoch "$(now_epoch)"
state_set phase switched
grafana_annotate "Switch: role $PKI_ROLE now signs with $issuer"

log "PASS role $PKI_ROLE signs with $issuer (switch recorded at $(state_get switch_time))"
log "Next: ./scripts/rollover/05-verify.sh (waits for the next ESO refresh; add --force-refresh to skip the wait)"
