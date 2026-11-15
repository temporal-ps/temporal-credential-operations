#!/usr/bin/env bash
# Verify milestone 2 after the migration switch. Exits non-zero on the first
# failed check.
#
#  1. Every proxy replica is Ready and mounts the ESO-managed Secret.
#  2. Each ExternalSecret is Ready and its Secret holds a leaf signed by the
#     Vault issuer recorded in rotation-state.
#  3. Gate: every expected proxy reports, every loaded leaf was issued after
#     the switch (NotAfter >= switch + leaf TTL - skew), and no TLS reload
#     failures in the last 15 minutes.
#  4. Probes: calls succeed in the last minute with no failures. Failures
#     since the switch (the one rolling restart) are reported, not fatal.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl

PROBE_WINDOW="${PROBE_WINDOW:-60s}"

[ "$(state_get leaf_source)" = "vault" ] || fail "leaf source is not vault; run ./scripts/migrate-switch.sh"
issuer="$(state_get new_issuer)"
pem="$STATE_DIR/$issuer.pem"
[ -f "$pem" ] || fail "missing $pem"
switch_epoch="$(state_get switch_epoch)"

expected=0
for ns in "${CLIENT_NAMESPACES[@]}"; do
  ready="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.status.readyReplicas}')"
  want="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.spec.replicas}')"
  [ "${ready:-0}" = "$want" ] || fail "$ns: temporal-proxy ready ${ready:-0}/$want"
  expected=$((expected + want))
  secrets="$(kc -n "$ns" get pods -l app.kubernetes.io/name=temporal-proxy \
    -o jsonpath='{range .items[*]}{.spec.volumes[?(@.name=="cloud-leaf")].secret.secretName}{"\n"}{end}' | sort -u)"
  [ "$secrets" = "temporal-cloud-leaf" ] || fail "$ns: proxy Pods mount '$(paste -sd, - <<<"$secrets")', expected temporal-cloud-leaf"
  log "PASS $ns: temporal-proxy ready $ready/$want, mounting temporal-cloud-leaf"

  status="$(kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  [ "$status" = "True" ] || fail "$ns: ExternalSecret temporal-cloud-leaf not Ready"
  crt="$(kc -n "$ns" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' | base64 -d)"
  openssl verify -CAfile "$pem" <(printf '%s\n' "$crt") >/dev/null 2>&1 \
    || fail "$ns: Secret temporal-cloud-leaf is not signed by $issuer"
  refreshed="$(kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.status.refreshTime}')"
  log "PASS $ns: ExternalSecret Ready (last refresh $refreshed), leaf signed by $issuer"
done

# Prometheus keeps returning a terminated Pod's series for a few minutes, so
# count only series from Pods Kubernetes currently reports as Ready.
ready_pods="$(ready_proxy_pods | jq -R . | jq -sc .)"
series="$(prom_query 'tmprl_proxy_tls_cert_expiry_timestamp_seconds{file="cert"}' \
  | jq --argjson ready "$ready_pods" \
    '.data.result |= map(select(("\(.metric.namespace)/\(.metric.pod)") as $p | $ready | index($p)))')"
count="$(jq '.data.result | length' <<<"$series")"
[ "$count" -eq "$expected" ] || fail "gate: $count of $expected Ready proxy Pods report a loaded leaf"
log "PASS gate: $count of $expected Ready proxy Pods report a loaded leaf"

min_not_after=$((switch_epoch + LEAF_TTL_SECONDS - GATE_SKEW_SECONDS))
stale="$(jq -r --argjson min "$min_not_after" \
  '.data.result[] | select((.value[1]|tonumber) < $min) | "\(.metric.namespace)/\(.metric.pod) NotAfter \(.value[1])"' <<<"$series")"
[ -z "$stale" ] || fail "gate: proxies still on a pre-switch leaf: $stale"
while read -r ns pod value; do
  log "PASS gate: $ns/$pod loaded leaf NotAfter $(epoch_to_iso "${value%.*}")"
done < <(jq -r '.data.result[] | "\(.metric.namespace) \(.metric.pod) \(.value[1])"' <<<"$series")

failures="$(prom_query 'sum(increase(tmprl_proxy_tls_reloads_total{result="failure"}[15m])) or vector(0)' \
  | jq -r '.data.result[0].value[1] | tonumber | floor')"
[ "$failures" = "0" ] || fail "gate: $failures TLS reload failures in the last 15 minutes"
log "PASS gate: no TLS reload failures in the last 15 minutes"

for ns in "${CLIENT_NAMESPACES[@]}"; do
  logs="$(kc -n "$ns" logs deploy/cli-probe --since="$PROBE_WINDOW")"
  ok="$(grep -c ' ok ' <<<"$logs" || true)"
  bad="$(grep -c ' FAIL ' <<<"$logs" || true)"
  [ "$ok" -gt 0 ] || fail "$ns: no successful probe calls in the last $PROBE_WINDOW"
  [ "$bad" -eq 0 ] || { grep ' FAIL ' <<<"$logs" | tail -3 >&2; fail "$ns: $bad failed probe calls in the last $PROBE_WINDOW"; }
  since_switch="$(kc -n "$ns" logs deploy/cli-probe --since-time="$(state_get switch_time)" | grep -c ' FAIL ' || true)"
  log "PASS $ns: $ok probe calls succeeded in the last $PROBE_WINDOW, 0 failed ($since_switch failed since the switch)"
done

log "Milestone 2 migration verified. Next: ./scripts/watch-renewals.sh"
