#!/usr/bin/env bash
# Watch routine leaf renewals with no operator action: ESO refreshes every
# 10 minutes, Vault signs a new leaf, the kubelet updates the mounted Secret,
# and each proxy reloads it.
#
# Usage: ./scripts/watch-renewals.sh [RENEWALS]   (default 3)
#
# Polls Prometheus and logs each replica's reload with the delay since its
# namespace's last ExternalSecret refresh (kubelet sync + proxy poll + this
# script's poll interval).
#
# Verify (exits non-zero otherwise): every proxy replica loads RENEWALS new
# leaves; no proxy Pod restarts or is replaced; no TLS reload failures; no
# probe failures during the watch.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq

RENEWALS="${1:-3}"
POLL_SECONDS="${POLL_SECONDS:-15}"
timeout_s=$(( (RENEWALS + 1) * ESO_REFRESH_SECONDS + 300 ))

pods_and_restarts() {
  local ns
  for ns in "${CLIENT_NAMESPACES[@]}"; do
    kc -n "$ns" get pods -l app.kubernetes.io/name=temporal-proxy \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.containerStatuses[0].restartCount}{"\n"}{end}'
  done | sort
}

# Loaded-leaf NotAfter per Ready proxy Pod. Series from terminated Pods linger
# in Prometheus for a few minutes and are ignored.
leaf_values() {
  local ready
  ready="$(ready_proxy_pods | jq -R . | jq -sc .)"
  prom_query 'tmprl_proxy_tls_cert_expiry_timestamp_seconds{file="cert"}' \
    | jq -r --argjson ready "$ready" '.data.result[]
        | select(("\(.metric.namespace)/\(.metric.pod)") as $p | $ready | index($p))
        | "\(.metric.namespace)/\(.metric.pod) \(.value[1] | tonumber | floor)"' | sort
}

work="$(mktemp -d)"
trap 'rm -f "$work"/*; rmdir "$work"' EXIT

start_iso="$(date -u +%FT%TZ)"
start="$(now_epoch)"
baseline_pods="$(pods_and_restarts)"
leaf_values > "$work/current"
[ -s "$work/current" ] || fail "no proxy leaf series in Prometheus"
while read -r replica value; do
  f="$work/$(tr '/' '_' <<<"$replica")"
  printf '%s 0\n' "$value" > "$f"
done < "$work/current"
replicas="$(wc -l < "$work/current" | tr -d ' ')"
log "Watching $replicas proxy replicas for $RENEWALS renewals each (timeout ${timeout_s}s), from $start_iso"

while :; do
  leaf_values > "$work/current"
  done_replicas=0
  while read -r replica value; do
    f="$work/$(tr '/' '_' <<<"$replica")"
    [ -f "$f" ] || fail "new proxy replica $replica appeared during the watch"
    read -r last n < "$f"
    if [ "$value" -gt "$last" ]; then
      n=$((n + 1))
      ns="${replica%%/*}"
      refreshed="$(kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.status.refreshTime}')"
      refreshed_epoch="$(date -j -u -f %FT%TZ "$refreshed" +%s 2>/dev/null || date -u -d "$refreshed" +%s)"
      log "$(date -u +%FT%TZ) $replica renewal $n: NotAfter $(epoch_to_iso "$value"), ESO refresh $refreshed, loaded within $(( $(now_epoch) - refreshed_epoch ))s"
      printf '%s %s\n' "$value" "$n" > "$f"
    fi
    [ "$n" -lt "$RENEWALS" ] || done_replicas=$((done_replicas + 1))
  done < "$work/current"
  [ "$done_replicas" -lt "$replicas" ] || break
  [ $(( $(now_epoch) - start )) -lt "$timeout_s" ] || fail "timed out with $done_replicas of $replicas replicas at $RENEWALS renewals"
  sleep "$POLL_SECONDS"
done

[ "$(pods_and_restarts)" = "$baseline_pods" ] || fail "proxy Pods restarted or were replaced during the watch"
log "PASS no proxy Pod restarted or was replaced"

failures="$(prom_query "sum(increase(tmprl_proxy_tls_reloads_total{result=\"failure\"}[$(( $(now_epoch) - start + 60 ))s])) or vector(0)" \
  | jq -r '.data.result[0].value[1] | tonumber | floor')"
[ "$failures" = "0" ] || fail "$failures TLS reload failures during the watch"
log "PASS no TLS reload failures"

for ns in "${CLIENT_NAMESPACES[@]}"; do
  logs="$(kc -n "$ns" logs deploy/cli-probe --since-time="$start_iso")"
  ok="$(grep -c ' ok ' <<<"$logs" || true)"
  bad="$(grep -c ' FAIL ' <<<"$logs" || true)"
  [ "$bad" -eq 0 ] || { grep ' FAIL ' <<<"$logs" | tail -3 >&2; fail "$ns: $bad probe failures during the watch"; }
  log "PASS $ns: $ok probe calls during the watch, 0 failed"
done

log "PASS $RENEWALS renewals on every proxy replica with no restarts and no errors."
