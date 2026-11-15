#!/usr/bin/env bash
# Run a complete CA rollover, steps 0 to 6, and time each step. For demos:
# watch the Grafana dashboard while it runs.
#
# Usage: ./scripts/demo-rollover.sh [--force-refresh]
#
#   Default         Routine rollover: after the switch, wait for normal ESO
#                   renewal to carry the new issuer to every proxy.
#   --force-refresh Emergency rollover: force ESO to reissue every leaf right
#                   after the switch.
#
# CHANGES TEMPORAL CLOUD (adds the new CA, then removes the old one) and
# VAULT (new issuer, role switch, old issuer disabled), exactly as the
# individual steps do. Stops at the first step that fails; fix the cause and
# re-run that step, or roll back with ./scripts/rollover/rollback.sh.
#
# Verify: each step's own checks; exits 0 only if all seven pass.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

dir="$(dirname "${BASH_SOURCE[0]}")/rollover"
verify_args=()
[ "${1:-}" = "--force-refresh" ] && verify_args=(--force-refresh)

phase="$(state_get phase)"
case "$phase" in
  ""|retired|rolled-back) ;;
  *) fail "a rollover is in progress (phase=$phase); continue it step by step or roll it back" ;;
esac

start="$(now_epoch)"
timings=()
run_step() {
  local name="$1"; shift
  local t0; t0="$(now_epoch)"
  log ""
  log "=== $name ($(date -u +%T))"
  "$@" || fail "$name failed; see above"
  timings+=("$(printf '%-18s %4ss' "$name" $(( $(now_epoch) - t0 )))")
}

run_step "00 preflight"     "$dir/00-preflight.sh"
run_step "01 snapshot"      "$dir/01-snapshot.sh"
run_step "02 create issuer" "$dir/02-create-issuer.sh"
run_step "03 add trust"     "$dir/03-add-trust.sh"
run_step "04 switch"        "$dir/04-switch.sh"
run_step "05 verify"        "$dir/05-verify.sh" ${verify_args[@]+"${verify_args[@]}"}
run_step "06 retire"        "$dir/06-retire.sh"

log ""
log "Rollover complete in $(( $(now_epoch) - start ))s:"
printf '  %s\n' "${timings[@]}"
