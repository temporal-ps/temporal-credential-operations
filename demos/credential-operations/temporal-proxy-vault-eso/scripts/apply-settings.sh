#!/usr/bin/env bash
# Apply demo-settings.env (and any .env.local overrides) to the running demo.
# No cluster restart: Vault and ESO use the new values from their next
# renewal; only Prometheus restarts, and only when its alert rules change.
#
#   LEAF_TTL               Vault role temporal-client ttl and max_ttl
#   ESO_REFRESH_INTERVAL   refreshInterval of each client namespace's
#                          ExternalSecret
#   both                   alert thresholds (ConfigMap prometheus-rules)
#
# The other settings are read by the scripts on each run. Components that are
# not installed yet are skipped; up.sh and vault-eso-up.sh call this script.
#
# Leaves already issued keep their old lifetime, so a change settles within
# one old leaf lifetime.
#
# Verify (exits non-zero otherwise): the settings are consistent, and the
# role, each ExternalSecret, and the loaded rules read back the new values.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq

R="$ESO_REFRESH_SECONDS"
L="$LEAF_TTL_SECONDS"
[ "$R" -ge 30 ] || fail "ESO_REFRESH_INTERVAL must be at least 30s"
[ "$L" -ge $((3 * R)) ] || fail "LEAF_TTL ($LEAF_TTL) must be at least 3x ESO_REFRESH_INTERVAL ($ESO_REFRESH_INTERVAL)"
[ $((4 * GATE_SKEW_SECONDS)) -le "$R" ] || fail "GATE_CLOCK_SKEW_SECONDS must be at most a quarter of ESO_REFRESH_INTERVAL"
duration_seconds "$ISSUER_TTL" >/dev/null
log "Settings: refresh ${ESO_REFRESH_INTERVAL}, leaf TTL ${LEAF_TTL}, gate skew ${GATE_SKEW_SECONDS}s, issuer TTL ${ISSUER_TTL}"

# Vault role (created by bootstrap-issuer.sh, run from up.sh).
if kc -n "$VAULT_NAMESPACE" get pod vault-0 >/dev/null 2>&1 \
   && vault_exec read "$PKI_MOUNT/roles/$PKI_ROLE" >/dev/null 2>&1; then
  vault_exec patch "$PKI_MOUNT/roles/$PKI_ROLE" ttl="$L" max_ttl="$L" >/dev/null
  got="$(vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" | jq -r '"\(.data.ttl) \(.data.max_ttl)"')"
  [ "$got" = "$L $L" ] || fail "role $PKI_ROLE reads back ttl/max_ttl '$got', expected '$L $L'"
  log "PASS role $PKI_ROLE ttl=max_ttl=${L}s"
else
  log "INFO role $PKI_ROLE not created yet; bootstrap-issuer.sh creates it with LEAF_TTL"
fi

# ExternalSecrets (exist once ESO resources are applied).
apply_eso_refresh_interval

# Alert rules.
if kc get namespace "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1; then
  rendered="$(sed "s/\${RENEWAL_STALLED_SECONDS}/$((L - 2 * R))/g" "$DEMO_DIR/k8s/observability/rules.yml.tmpl")"
  current="$(kc -n "$OBSERVABILITY_NAMESPACE" get configmap prometheus-rules -o jsonpath='{.data.rules\.yml}' 2>/dev/null || true)"
  if [ "$rendered" = "$current" ]; then
    log "PASS alert rules already current (renewal-stalled threshold $((L - 2 * R))s)"
  else
    kc -n "$OBSERVABILITY_NAMESPACE" create configmap prometheus-rules \
      --from-literal=rules.yml="$rendered" --dry-run=client -o yaml | kc apply -f - >/dev/null
    if kc -n "$OBSERVABILITY_NAMESPACE" get deploy prometheus >/dev/null 2>&1; then
      kc -n "$OBSERVABILITY_NAMESPACE" rollout restart deploy/prometheus >/dev/null
      kc -n "$OBSERVABILITY_NAMESPACE" rollout status deploy/prometheus --timeout=180s >/dev/null
      want_rules="$(grep -c '^ *- alert:' <<<"$rendered")"
      deadline=$(( $(now_epoch) + 60 ))
      until [ "$(prom_query_api rules | jq '[.data.groups[].rules[]] | length' 2>/dev/null)" = "$want_rules" ]; do
        [ "$(now_epoch)" -lt "$deadline" ] || fail "Prometheus did not load the alert rules"
        sleep 3
      done
    fi
    log "PASS alert rules updated (renewal-stalled threshold $((L - 2 * R))s)"
  fi
fi

log "Expect: a routine rollover's verify step within about ${ESO_REFRESH_INTERVAL} + 2m of the switch; the demo tolerates about ${LEAF_TTL} of ESO or Vault outage."
