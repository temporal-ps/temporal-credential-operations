#!/usr/bin/env bash
# Verify the proxy path on Vault-issued leaves. Exits non-zero on the first
# failed check. Read only.
#
#  1. Every proxy replica is Ready and mounts the ESO-managed Secret
#     temporal-cloud-leaf.
#  2. Each ExternalSecret is Ready and its Secret holds a leaf signed by the
#     issuer the Vault role points at.
#  3. Each CLI probe has recent successful calls through its namespace's proxy
#     and no failures in its recent log window.
#  4. Prometheus scrapes every Ready proxy replica, and each reports a loaded
#     leaf that is unexpired and no more than RELOAD_LAG_SECONDS older than
#     the mounted one. The Secret changes every refresh and the proxy loads it
#     only after kubelet syncs the volume and its next poll, so the loaded
#     leaf normally trails the mounted one.
#  5. No TLS reload failures are recorded.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl

PROBE_WINDOW="${PROBE_WINDOW:-60s}"
# Kubelet volume sync (up to about 2 minutes) plus the proxy's 1-minute poll
# plus the 15-second Prometheus scrape.
RELOAD_LAG_SECONDS="${RELOAD_LAG_SECONDS:-200}"

issuer="$(role_issuer)"
[ -n "$issuer" ] && [ "$issuer" != "null" ] || fail "Vault role $PKI_ROLE has no issuer; run ./scripts/up.sh"
pem="$(mktemp)"
trap 'rm -f "$pem"' EXIT
issuer_cert "$issuer" > "$pem"

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
  log "PASS $ns: ExternalSecret Ready, leaf signed by $issuer"

  logs="$(kc -n "$ns" logs deploy/cli-probe --since="$PROBE_WINDOW")"
  ok="$(grep -c ' ok ' <<<"$logs" || true)"
  bad="$(grep -c ' FAIL ' <<<"$logs" || true)"
  [ "$ok" -gt 0 ] || fail "$ns: no successful probe calls in the last $PROBE_WINDOW"
  [ "$bad" -eq 0 ] || { grep ' FAIL ' <<<"$logs" | tail -3 >&2; fail "$ns: $bad failed probe calls in the last $PROBE_WINDOW"; }
  log "PASS $ns: $ok probe calls succeeded through the proxy in the last $PROBE_WINDOW, 0 failed"
done

# Prometheus keeps returning a terminated Pod's series for a few minutes, so
# count only series from Pods Kubernetes currently reports as Ready.
# Right after up.sh, a new Pod may not have had its first scrape yet, so allow
# SCRAPE_WAIT_SECONDS for every Ready proxy to appear.
SCRAPE_WAIT_SECONDS="${SCRAPE_WAIT_SECONDS:-60}"
deadline=$(( $(now_epoch) + SCRAPE_WAIT_SECONDS ))
while :; do
  ready_pods="$(ready_proxy_pods | jq -R . | jq -sc .)"
  series="$(prom_query 'tmprl_proxy_tls_cert_expiry_timestamp_seconds{file="cert"}' \
    | jq --argjson ready "$ready_pods" \
      '[.data.result[] | select(("\(.metric.namespace)/\(.metric.pod)") as $p | $ready | index($p))]')"
  count="$(jq 'length' <<<"$series")"
  [ "$count" -lt "$expected" ] && [ "$(now_epoch)" -lt "$deadline" ] || break
  sleep 5
done
[ "$count" -eq "$expected" ] || fail "$count of $expected Ready proxy replicas report a loaded leaf after ${SCRAPE_WAIT_SECONDS}s"
log "PASS Prometheus: $count of $expected proxy replicas report a loaded leaf"

while read -r ns pod value; do
  mounted="$(kc -n "$ns" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -enddate)"
  file_epoch="$(openssl_date_to_epoch "${mounted#notAfter=}")"
  gauge_epoch="${value%.*}"
  gauge_iso="$(epoch_to_iso "$gauge_epoch")"
  behind=$((file_epoch - gauge_epoch))
  [ "$gauge_epoch" -gt "$(now_epoch)" ] || fail "$ns/$pod: loaded leaf expired at $gauge_iso"
  [ "$behind" -ge 0 ] || fail "$ns/$pod: loaded leaf NotAfter $gauge_epoch is later than the mounted certificate $file_epoch"
  [ "$behind" -le "$RELOAD_LAG_SECONDS" ] \
    || fail "$ns/$pod: loaded leaf is ${behind}s older than the mounted certificate (allowed ${RELOAD_LAG_SECONDS}s); the proxy is not reloading"
  log "PASS $ns/$pod: loaded leaf NotAfter $gauge_iso, ${behind}s behind the mounted certificate (allowed ${RELOAD_LAG_SECONDS}s)"
done < <(jq -r '.[] | "\(.metric.namespace) \(.metric.pod) \(.value[1])"' <<<"$series")

failures="$(prom_query 'sum(tmprl_proxy_tls_reloads_total{result="failure"}) or vector(0)' | jq -r '.data.result[0].value[1]')"
[ "$failures" = "0" ] || fail "proxies report $failures TLS reload failures"
log "PASS no TLS reload failures"

log "Proxy path verified."
