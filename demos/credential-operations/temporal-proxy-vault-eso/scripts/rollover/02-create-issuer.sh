#!/usr/bin/env bash
# Rollover step 2: create a new Vault PKI issuer ca-<UTC timestamp> with a
# private key generated and held inside Vault, and export its public
# certificate to .state/<issuer>.pem for step 3.
#
# Does not change what Vault signs: the temporal-client role keeps pointing at
# the old issuer until step 4.
#
# Idempotent: re-running after success reuses the recorded issuer.
#
# Verify: the issuer is listed in the mount, the exported certificate is a CA
# certificate matching it, the role's issuer is unchanged, and no private key
# was written.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl jq openssl

phase="$(state_get phase)"
case "$phase" in
  snapshot|issuer-created) ;;
  *) fail "expected phase snapshot or issuer-created, found '${phase:-none}'; run 01-snapshot.sh" ;;
esac

vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" >/dev/null 2>&1 \
  || fail "role $PKI_ROLE does not exist; run ./scripts/up.sh"

# Reuse only on a re-run of this step. After a completed rollover, new_issuer
# still names that rollover's issuer, which is now the one in use.
issuer=""
[ "$phase" != "issuer-created" ] || issuer="$(state_get new_issuer)"
if [ -n "$issuer" ] && vault_exec read -format=json "$PKI_MOUNT/issuer/$issuer" >/dev/null 2>&1; then
  log "Issuer $issuer already created; reusing it"
else
  issuer="$(create_issuer)"
  log "Created issuer $issuer"
fi

pem="$(export_issuer_pem "$issuer")"
fp="$(cert_sha1 < "$pem")"
role_issuer="$(role_issuer)"
# Check before recording, so a refusal leaves rotation-state unchanged.
[ "$role_issuer" != "$issuer" ] || fail "role $PKI_ROLE already points at $issuer before step 4"

state_set new_issuer "$issuer"
state_set new_ca_fingerprint "$fp"
state_set phase issuer-created

log "Issuer:        $issuer"
openssl x509 -in "$pem" -noout -subject -enddate | sed 's/^/  /'
log "Fingerprint:   $fp (SHA-1)"
log "Certificate:   $pem (public only)"
log "PASS role $PKI_ROLE still points at $role_issuer"
