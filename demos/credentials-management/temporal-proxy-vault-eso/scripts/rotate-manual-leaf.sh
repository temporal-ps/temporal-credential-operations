#!/usr/bin/env bash
# Milestone 1 hot-reload check, still in the "manual CA" world.
#
# Signs a short-lived client leaf with the bootstrap CA key (locally, as the
# manual procedure would), replaces Secret temporal-cloud-leaf-manual in every
# client namespace, and waits until every proxy replica reports the new leaf's
# NotAfter, with no restart. The leaf chains to the CA the Namespace already
# trusts, so no Temporal Cloud change is involved.
#
# Demo only: in the target state Vault PKI signs leaves and no CA key exists
# outside Vault.
#
# Verify: the script exits 0 only when every replica reports the new NotAfter,
# Pod restart counts are unchanged, and no reload failures occurred.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl openssl jq
require_demo_ca

LEAF_DAYS="${LEAF_DAYS:-2}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

cat > "$work/ext.cnf" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF

openssl req -new -newkey rsa:2048 -nodes -keyout "$work/leaf.key" \
  -subj "/O=temporal/CN=temporal-proxy-manual-$(date -u +%Y%m%dT%H%M%SZ)" \
  -out "$work/leaf.csr" 2>/dev/null
openssl x509 -req -in "$work/leaf.csr" -CA "$MANUAL_CERT_FILE" -CAkey "$MANUAL_KEY_FILE" \
  -CAcreateserial -CAserial "$work/ca.srl" -days "$LEAF_DAYS" -sha256 \
  -extfile "$work/ext.cnf" -out "$work/leaf.crt" 2>/dev/null
openssl verify -CAfile "$MANUAL_CERT_FILE" "$work/leaf.crt" >/dev/null || fail "new leaf does not chain to the bootstrap CA"

log "New leaf:"
describe_cert < "$work/leaf.crt" | sed 's/^/  /'
leaf_end="$(openssl x509 -in "$work/leaf.crt" -noout -enddate)"
want_epoch="$(date -j -u -f '%b %e %T %Y %Z' "${leaf_end#notAfter=}" +%s 2>/dev/null \
  || date -u -d "${leaf_end#notAfter=}" +%s)"

restarts_before=""
for ns in "${CLIENT_NAMESPACES[@]}"; do
  restarts_before="$restarts_before $ns:$(kc -n "$ns" get pods -l app.kubernetes.io/name=temporal-proxy \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount},{end}')"
  kc -n "$ns" create secret tls temporal-cloud-leaf-manual \
    --cert="$work/leaf.crt" --key="$work/leaf.key" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  log "$ns: Secret temporal-cloud-leaf-manual replaced at $(date -u +%FT%TZ)"
done

start="$(date +%s)"
expected=0
for ns in "${CLIENT_NAMESPACES[@]}"; do
  expected=$((expected + $(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.spec.replicas}')))
done
while :; do
  done_count="$(prom_query "count(tmprl_proxy_tls_cert_expiry_timestamp_seconds{file=\"cert\"} == $want_epoch) or vector(0)" \
    | jq -r '.data.result[0].value[1]')"
  elapsed=$(( $(date +%s) - start ))
  log "  ${elapsed}s: $done_count of $expected proxy replicas report the new leaf"
  [ "$done_count" -ge "$expected" ] && break
  [ "$elapsed" -lt "$TIMEOUT_SECONDS" ] || fail "timed out after ${TIMEOUT_SECONDS}s"
  sleep 15
done

restarts_after=""
for ns in "${CLIENT_NAMESPACES[@]}"; do
  restarts_after="$restarts_after $ns:$(kc -n "$ns" get pods -l app.kubernetes.io/name=temporal-proxy \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount},{end}')"
done
[ "$restarts_after" = "$restarts_before" ] || fail "proxy Pods or restart counts changed:$restarts_before ->$restarts_after"
log "PASS no proxy restarts"

failures="$(prom_query 'sum(tmprl_proxy_tls_reloads_total{result="failure"}) or vector(0)' | jq -r '.data.result[0].value[1]')"
[ "$failures" = "0" ] || fail "proxies report $failures TLS reload failures"
log "PASS hot reload: all $expected replicas loaded the new leaf in ~$(( $(date +%s) - start ))s without a restart"
