#!/usr/bin/env bash
# Standing check: fail when the Vault issuer the temporal-client role signs
# with expires within the rollover lead time. Issuer expiry is not a proxy
# metric, so run this on a schedule (production: or use a Vault-side metric).
#
# Usage: ./scripts/check-issuer-expiry.sh   (ISSUER_LEAD_DAYS in demo-settings.env)
#
# Read only. Verify: prints PASS and exits 0 when the issuer outlives the
# lead time; exits non-zero naming the issuer and its NotAfter otherwise.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl

LEAD_DAYS="$ISSUER_LEAD_DAYS"

issuer="$(role_issuer)"
[ -n "$issuer" ] && [ "$issuer" != "null" ] || fail "role $PKI_MOUNT/roles/$PKI_ROLE has no issuer"
not_after="$(issuer_cert "$issuer" | openssl x509 -noout -enddate | cut -d= -f2)"
not_after_epoch="$(openssl_date_to_epoch "$not_after")"
days_left=$(( (not_after_epoch - $(now_epoch)) / 86400 ))

[ "$days_left" -ge "$LEAD_DAYS" ] \
  || fail "issuer $issuer expires $(epoch_to_iso "$not_after_epoch") ($days_left days); start a rollover (lead time $LEAD_DAYS days)"
log "PASS issuer $issuer expires $(epoch_to_iso "$not_after_epoch") ($days_left days left, lead time $LEAD_DAYS days)"
