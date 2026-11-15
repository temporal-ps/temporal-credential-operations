#!/usr/bin/env bash
# Rollover step 5: wait for routine renewal to carry the new issuer to every
# proxy, then evaluate the retirement gate until it passes.
#
# Usage: ./scripts/rollover/05-verify.sh [--force-refresh]
#
#   --force-refresh  Emergency rollover: make ESO reissue every leaf now
#                    instead of waiting for the next refresh interval.
#
# Waits until switch + R (R = ESO refresh interval), or not at all after a
# forced refresh, then evaluates the gate every 15 seconds until it passes or
# GATE_TIMEOUT (default 2R + 5 minutes) elapses. Kubelet sync, the proxy's
# 1-minute poll, and scraping normally add 1 to 2 minutes after a refresh.
#
# Changes nothing except, with --force-refresh, the ExternalSecrets'
# force-sync annotation.
#
# Verify: exits 0 when the gate passes; on timeout prints each failing check
# (including every stale proxy and its leaf expiry) and exits non-zero.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl jq openssl

GATE_TIMEOUT="${GATE_TIMEOUT:-$((2 * ESO_REFRESH_SECONDS + 300))}"

phase="$(state_get phase)"
case "$phase" in
  switched|verified) ;;
  *) fail "expected phase switched, found '${phase:-none}'" ;;
esac

if [ "${1:-}" = "--force-refresh" ]; then
  "$(dirname "${BASH_SOURCE[0]}")/../force-refresh.sh"
  ready_at="$(now_epoch)"
else
  ready_at=$(( $(state_get switch_epoch) + ESO_REFRESH_SECONDS ))
fi

wait_s=$(( ready_at - $(now_epoch) ))
if [ "$wait_s" -gt 0 ]; then
  log "Waiting ${wait_s}s, until $(epoch_to_iso "$ready_at"), for the first ESO refresh after the switch"
  sleep "$wait_s"
fi

deadline=$(( $(now_epoch) + GATE_TIMEOUT ))
attempt=0
until out="$(gate_evaluate)"; do
  attempt=$((attempt + 1))
  if [ "$(now_epoch)" -ge "$deadline" ]; then
    printf '%s\n' "$out"
    fail "gate did not pass within ${GATE_TIMEOUT}s; do not retire. Walk the delivery chain back from each FAIL above (proxy, Secret, ExternalSecret, Vault)."
  fi
  [ $((attempt % 4)) -ne 1 ] || log "  $(date -u +%T) gate not passing yet: $(grep '^FAIL' <<<"$out" | head -1 | sed 's/^FAIL gate: //') ($(grep -c '^FAIL' <<<"$out") failing)"
  sleep 15
done
printf '%s\n' "$out"

state_set phase verified
state_set verify_time "$(date -u +%FT%TZ)"
log "Gate passed. Next: ./scripts/rollover/06-retire.sh"
