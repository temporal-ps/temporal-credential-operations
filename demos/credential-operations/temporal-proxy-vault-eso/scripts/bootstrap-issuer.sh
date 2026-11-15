#!/usr/bin/env bash
# Set up the starting state: a Vault PKI issuer the demo Namespace trusts, so
# the proxies run on Vault-issued leaves from their first start.
#
#   1. Issuer: on a new cluster, create issuer ca-<timestamp> (key generated
#      inside Vault) and role temporal-client pointing at it. On an existing
#      cluster, reuse the issuer the role points at.
#   2. Trust: if the Namespace does not accept that issuer, REPLACE ITS
#      ACCEPTED CLIENT CAs with the issuer's certificate (tcld
#      accepted-client-ca set, at the current resource version). This happens
#      only on a new cluster. The Namespace is dedicated to the demo, and the
#      CAs replaced belong to earlier demo clusters whose dev-mode Vault, and
#      signing keys, no longer exist.
#
# CHANGES VAULT (first issuer and role) and, on a new cluster, TEMPORAL CLOUD.
# Refuses to touch trust while a rollover is in progress.
#
# Idempotent. Prints certificate metadata only, never key material.
#
# Verify (exits non-zero otherwise):
#   1. The role points at the issuer.
#   2. The Namespace accepts the issuer's CA (exactly that CA after a replace).
#   3. A call with a 5-minute test leaf from the issuer succeeds.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl tcld temporal
resolve_target
use_ops_api_key

PROPAGATION_TIMEOUT="${PROPAGATION_TIMEOUT:-900}"   # seconds

if vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" >/dev/null 2>&1; then
  issuer="$(role_issuer)"
  log "Role $PKI_ROLE exists; current issuer $issuer"
else
  issuer="$(create_issuer)"
  create_pki_role "$issuer"
  log "Created issuer $issuer and role $PKI_ROLE pointing at it"
fi
[ "$(role_issuer)" = "$issuer" ] || fail "role $PKI_ROLE does not point at $issuer"
pem="$(export_issuer_pem "$issuer")"
fp="$(cert_sha1 < "$pem")"
openssl x509 -in "$pem" -noout -subject -enddate | sed 's/^/  /'
log "PASS role $PKI_ROLE signs with $issuer ($fp)"

deadline=$(( $(now_epoch) + PROPAGATION_TIMEOUT ))
if grep -qx "$fp" <<<"$(accepted_ca_fingerprints)"; then
  log "PASS $TEMPORAL_NAMESPACE already accepts $issuer"
else
  phase="$(state_get phase)"
  case "$phase" in
    ""|retired|rolled-back) ;;
    *) fail "rollover in progress (phase=$phase) but $TEMPORAL_NAMESPACE does not accept the role's issuer; not replacing trust" ;;
  esac
  log "Replacing $TEMPORAL_NAMESPACE accepted client CAs ($(accepted_ca_fingerprints | paste -sd, -)) with $issuer ($fp)"
  tcld --auto_confirm namespace accepted-client-ca set \
    -n "$TEMPORAL_NAMESPACE" \
    --ca-certificate-file "$pem" \
    --resource-version "$(tcld namespace get -n "$TEMPORAL_NAMESPACE" | jq -r '.resourceVersion')" \
    --request-id "set-ca-$issuer" >/dev/null
  until [ "$(accepted_ca_fingerprints)" = "$fp" ]; do
    [ "$(now_epoch)" -lt "$deadline" ] || fail "$TEMPORAL_NAMESPACE never listed exactly $fp: $(accepted_ca_fingerprints | paste -sd, -)"
    sleep 10
  done
  log "PASS $TEMPORAL_NAMESPACE accepts exactly $issuer ($fp)"
fi

prove_issuer_accepted "$issuer" "$deadline"
