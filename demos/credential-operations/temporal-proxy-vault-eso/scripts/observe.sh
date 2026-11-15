#!/usr/bin/env bash
# Port-forward Grafana (http://localhost:3000, anonymous viewer) and Prometheus
# (http://localhost:9090) until interrupted. Tails probe logs in the foreground.
#
# Grafana admin password (for editing): kubectl --context k3d-tco-proxy-vault-eso
#   -n observability get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
kc -n "$OBSERVABILITY_NAMESPACE" port-forward svc/grafana 3000:3000 >/dev/null & pids+=($!)
kc -n "$OBSERVABILITY_NAMESPACE" port-forward svc/prometheus 9090:9090 >/dev/null & pids+=($!)
log "Grafana:    http://localhost:3000/d/temporal-proxy-rotation"
log "Prometheus: http://localhost:9090"
log "Tailing probe logs (Ctrl-C to stop)..."
for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc -n "$ns" logs -f deploy/cli-probe --tail=3 --prefix & pids+=($!)
done
wait
