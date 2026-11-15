#!/usr/bin/env bash
# Rollover step 2: create a new Vault PKI issuer ca-<UTC timestamp> with a
# private key generated and held inside Vault, and export its public
# certificate to .state/<issuer>.pem for step 3.
#
# Does not change what Vault signs: the temporal-client role keeps pointing at
# the old issuer until step 4. Exception, first run only: if the role does not
# exist yet, it is created pointing at the new issuer. Nothing requests leaves
# from it until the migration switch applies the ESO resources.
#
# Idempotent: re-running after success reuses the recorded issuer.
#
# Verify: the issuer is listed in the mount, the exported certificate is a CA
# certificate matching it, the role's issuer is unchanged (or, on the first
# run, is the new issuer), and no private key was written.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl jq openssl

phase="$(state_get phase)"
case "$phase" in
  snapshot|issuer-created) ;;
  *) fail "expected phase snapshot or issuer-created, found '${phase:-none}'; run 01-snapshot.sh" ;;
esac

mkdir -p "$STATE_DIR"
issuer="$(state_get new_issuer)"
if [ -n "$issuer" ] && vault_exec read -format=json "$PKI_MOUNT/issuer/$issuer" >/dev/null 2>&1; then
  log "Issuer $issuer already created; reusing it"
else
  issuer="ca-$(date -u +%Y%m%dT%H%M%SZ)"
  # root/generate/internal: the key never leaves Vault, the response has no key.
  vault_exec write -format=json "$PKI_MOUNT/root/generate/internal" \
    common_name="Acme Temporal client CA $issuer" \
    organization="Acme" \
    issuer_name="$issuer" key_name="key-$issuer" \
    key_type=ec key_bits=256 ttl=8760h >/dev/null
  log "Created issuer $issuer"
fi

pem="$STATE_DIR/$issuer.pem"
vault_exec read -format=json "$PKI_MOUNT/issuer/$issuer" | jq -r '.data.certificate' > "$pem"
fp="$(cert_sha1 < "$pem")"
openssl x509 -in "$pem" -noout -text | grep -q 'CA:TRUE' || fail "$pem is not a CA certificate"
grep -q 'PRIVATE KEY' "$pem" && fail "$pem contains a private key"

role_issuer=""
if vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" >/dev/null 2>&1; then
  role_issuer="$(vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" | jq -r '.data.issuer_ref')"
else
  # First run: create the role pointing at the first issuer. Demo lifetimes.
  vault_exec write "$PKI_MOUNT/roles/$PKI_ROLE" \
    issuer_ref="$issuer" \
    ttl=30m max_ttl=30m \
    key_type=ec key_bits=256 \
    client_flag=true server_flag=false \
    allowed_domains="workers.temporal-proxy,callers.temporal-proxy" \
    allow_bare_domains=true allow_subdomains=false allow_localhost=false \
    enforce_hostnames=false \
    no_store=true generate_lease=false >/dev/null
  role_issuer="$issuer"
  state_set role_created_by "$issuer"
  log "Created role $PKI_ROLE with issuer_ref=$issuer (first run)"
fi

state_set new_issuer "$issuer"
state_set new_ca_fingerprint "$fp"
state_set phase issuer-created

log "Issuer:        $issuer"
openssl x509 -in "$pem" -noout -subject -enddate | sed 's/^/  /'
log "Fingerprint:   $fp (SHA-1)"
log "Certificate:   $pem (public only)"
if [ "$(state_get role_created_by)" = "$issuer" ]; then
  log "PASS role $PKI_ROLE was created for the migration and points at $issuer"
else
  [ "$role_issuer" != "$issuer" ] || fail "role $PKI_ROLE already points at $issuer before step 4"
  log "PASS role $PKI_ROLE still points at $role_issuer"
fi
