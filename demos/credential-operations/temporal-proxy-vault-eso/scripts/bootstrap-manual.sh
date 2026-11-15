#!/usr/bin/env bash
# Set up the starting state: the bootstrap CA (generated outside Vault)
# trusted by the demo Namespace, and handed to the proxies as Secret
# temporal-cloud-leaf-manual in each client namespace.
#
# Trust: while the proxies use the manual CA (leaf_source is not vault), make
# sure the Namespace accepts the bootstrap CA. A previous run's 06-retire.sh
# removes it, so a new run adds it back. CHANGES TEMPORAL CLOUD only when the
# CA is missing: one additive accepted-client-ca add.
#
# Idempotent. Prints certificate metadata only, never key material.
#
# Verify (exits non-zero otherwise):
#   1. The Namespace accepts the bootstrap CA, and a call presenting it
#      succeeds (retried while a new CA propagates).
#   2. Each namespace's Secret certificate matches the bootstrap file.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl openssl

require_demo_ca
PROPAGATION_TIMEOUT="${PROPAGATION_TIMEOUT:-900}"   # seconds

if [ "$(state_get leaf_source)" != "vault" ]; then
  require_tools tcld jq temporal
  resolve_target
  use_ops_api_key
  fp="$(cert_sha1 < "$MANUAL_CERT_FILE")"
  if grep -qx "$fp" <<<"$(accepted_ca_fingerprints)"; then
    log "PASS $TEMPORAL_NAMESPACE already accepts the bootstrap CA ($fp)"
  else
    log "Adding the bootstrap CA ($fp) to $TEMPORAL_NAMESPACE accepted client CAs"
    tcld --auto_confirm namespace accepted-client-ca add \
      -n "$TEMPORAL_NAMESPACE" \
      --ca-certificate-file "$MANUAL_CERT_FILE" \
      --resource-version "$(tcld namespace get -n "$TEMPORAL_NAMESPACE" | jq -r '.resourceVersion')" \
      --request-id "add-bootstrap-ca-$fp-$(date -u +%Y%m%d%H%M)" >/dev/null
  fi
  deadline=$(( $(now_epoch) + PROPAGATION_TIMEOUT ))
  until grep -qx "$fp" <<<"$(accepted_ca_fingerprints)"; do
    [ "$(now_epoch)" -lt "$deadline" ] || fail "$TEMPORAL_NAMESPACE never listed the bootstrap CA"
    sleep 10
  done
  until temporal workflow count \
      --address "$TEMPORAL_CLOUD_ENDPOINT" --namespace "$TEMPORAL_NAMESPACE" \
      --tls-cert-path "$MANUAL_CERT_FILE" --tls-key-path "$MANUAL_KEY_FILE" \
      --command-timeout 10s >/dev/null 2>&1; do
    [ "$(now_epoch)" -lt "$deadline" ] || fail "$TEMPORAL_NAMESPACE still rejects the bootstrap CA after ${PROPAGATION_TIMEOUT}s"
    sleep 10
  done
  log "PASS a call presenting the bootstrap CA succeeds against $TEMPORAL_NAMESPACE"
fi

want="$(openssl x509 -in "$MANUAL_CERT_FILE" -noout -fingerprint -sha256)"
log "Bootstrap certificate:"
describe_cert < "$MANUAL_CERT_FILE" | sed 's/^/  /'

for ns in "${CLIENT_NAMESPACES[@]}"; do
  kc -n "$ns" create secret tls temporal-cloud-leaf-manual \
    --cert="$MANUAL_CERT_FILE" --key="$MANUAL_KEY_FILE" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  got="$(kc -n "$ns" get secret temporal-cloud-leaf-manual -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -fingerprint -sha256)"
  [ "$got" = "$want" ] || fail "$ns: Secret certificate does not match $MANUAL_CERT_FILE"
  log "$ns: temporal-cloud-leaf-manual matches the bootstrap certificate"
done
