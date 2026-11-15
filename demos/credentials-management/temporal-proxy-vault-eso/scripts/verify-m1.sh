#!/usr/bin/env bash
# Verify milestone 1. Exits non-zero on the first failed check.
#
#  1. Every proxy replica is Ready.
#  2. Each CLI probe has recent successful calls through its namespace's proxy
#     and no failures in its recent log window.
#  3. Prometheus scrapes every proxy replica and each reports the loaded leaf's
#     NotAfter, which equals the NotAfter of the certificate mounted in the Pod.
#  4. No TLS reload failures are recorded.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl

PROBE_WINDOW="${PROBE_WINDOW:-60s}"

expected=0
for ns in "${CLIENT_NAMESPACES[@]}"; do
  ready="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.status.readyReplicas}')"
  want="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.spec.replicas}')"
  [ "${ready:-0}" = "$want" ] || fail "$ns: temporal-proxy ready ${ready:-0}/$want"
  expected=$((expected + want))
  log "PASS $ns: temporal-proxy ready $ready/$want"

  logs="$(kc -n "$ns" logs deploy/cli-probe --since="$PROBE_WINDOW")"
  ok="$(grep -c ' ok ' <<<"$logs" || true)"
  bad="$(grep -c ' FAIL ' <<<"$logs" || true)"
  [ "$ok" -gt 0 ] || fail "$ns: no successful probe calls in the last $PROBE_WINDOW"
  [ "$bad" -eq 0 ] || { grep ' FAIL ' <<<"$logs" | tail -3 >&2; fail "$ns: $bad failed probe calls in the last $PROBE_WINDOW"; }
  log "PASS $ns: $ok probe calls succeeded through the proxy in the last $PROBE_WINDOW, 0 failed"
done

series="$(prom_query 'tmprl_proxy_tls_cert_expiry_timestamp_seconds{file="cert"}')"
count="$(jq '.data.result | length' <<<"$series")"
[ "$count" -eq "$expected" ] || fail "Prometheus reports $count proxy leaf series, expected $expected"
log "PASS Prometheus: $count of $expected proxy replicas report a loaded leaf"

while read -r ns pod value; do
  # The proxy image has no shell; read the Secret the Pod mounts.
  secret="$(kc -n "$ns" get pod "$pod" -o jsonpath='{.spec.volumes[?(@.name=="cloud-leaf")].secret.secretName}')"
  mounted="$(kc -n "$ns" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate)"
  file_epoch="$(date -j -u -f '%b %e %T %Y %Z' "${mounted#notAfter=}" +%s 2>/dev/null \
    || date -u -d "${mounted#notAfter=}" +%s)"
  gauge_epoch="${value%.*}"
  [ "$file_epoch" = "$gauge_epoch" ] || fail "$ns/$pod: gauge NotAfter $gauge_epoch != mounted certificate $file_epoch"
  log "PASS $ns/$pod: loaded leaf NotAfter $(date -u -r "$gauge_epoch" +%FT%TZ 2>/dev/null || date -u -d "@$gauge_epoch" +%FT%TZ) matches the mounted certificate"
done < <(jq -r '.data.result[] | "\(.metric.namespace) \(.metric.pod) \(.value[1])"' <<<"$series")

failures="$(prom_query 'sum(tmprl_proxy_tls_reloads_total{result="failure"}) or vector(0)' | jq -r '.data.result[0].value[1]')"
[ "$failures" = "0" ] || fail "proxies report $failures TLS reload failures"
log "PASS no TLS reload failures"

log "Milestone 1 verified."
