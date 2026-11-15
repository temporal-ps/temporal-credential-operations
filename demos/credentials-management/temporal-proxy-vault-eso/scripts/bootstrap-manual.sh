#!/usr/bin/env bash
# Create Secret temporal-cloud-leaf-manual in each client namespace from the
# manually generated client CA certificate and key. This mirrors the starting
# state: certificate material produced outside Vault and handed to workloads.
#
# Idempotent. Prints certificate metadata only, never key material.
#
# Verify: each namespace's Secret certificate matches the source file's
# fingerprint (checked below; exits non-zero on mismatch).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl openssl

require_demo_ca

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
