#!/usr/bin/env bash
# Rollover step 3: add the new issuer's CA certificate to the Namespace's
# accepted client CAs, then prove Temporal Cloud accepts a leaf it signs.
#
# CHANGES TEMPORAL CLOUD: adds one accepted client CA. Additive only; nothing
# is removed. Uses the Snapshot's resource version, so the add fails rather
# than overwriting a concurrent change to the Namespace.
#
# Idempotent: skips the add if the fingerprint is already accepted.
#
# Verify:
#   1. The accepted set equals the Snapshot set plus the new fingerprint.
#   2. A 5-minute test leaf from the new issuer completes a call against the
#      Namespace (retried while the CA change propagates).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_tools kubectl tcld jq openssl temporal
resolve_target
use_ops_api_key

PROPAGATION_TIMEOUT="${PROPAGATION_TIMEOUT:-900}"   # seconds

phase="$(state_get phase)"
case "$phase" in
  issuer-created|trusted) ;;
  *) fail "expected phase issuer-created or trusted, found '${phase:-none}'" ;;
esac

issuer="$(state_get new_issuer)"
new_fp="$(state_get new_ca_fingerprint)"
pem="$STATE_DIR/$issuer.pem"
[ -f "$pem" ] || fail "missing $pem; re-run 02-create-issuer.sh"
[ "$(cert_sha1 < "$pem")" = "$new_fp" ] || fail "$pem does not match the recorded fingerprint $new_fp"

snapshot="$(state_get accepted_cas | tr ',' '\n' | sort)"
want="$(printf '%s\n%s\n' "$snapshot" "$new_fp" | grep -v '^$' | sort -u)"

current="$(accepted_ca_fingerprints)"
if grep -qx "$new_fp" <<<"$current"; then
  log "$new_fp already accepted by $TEMPORAL_NAMESPACE; skipping add"
else
  [ "$current" = "$snapshot" ] \
    || fail "accepted CAs changed since the Snapshot; re-run 01-snapshot.sh after reviewing: $(paste -sd, - <<<"$current")"
  log "Adding $issuer ($new_fp) to $TEMPORAL_NAMESPACE accepted client CAs"
  tcld --auto_confirm namespace accepted-client-ca add \
    -n "$TEMPORAL_NAMESPACE" \
    --ca-certificate-file "$pem" \
    --resource-version "$(state_get resource_version)" \
    --request-id "add-ca-$issuer" | jq -r '"  request \(.requestId // .asyncOperation.id // "?"): \(.state // .asyncOperation.state // "submitted")"' || true
fi

deadline=$(( $(now_epoch) + PROPAGATION_TIMEOUT ))
until [ "$(accepted_ca_fingerprints)" = "$want" ]; do
  [ "$(now_epoch)" -lt "$deadline" ] || fail "accepted CAs never matched Snapshot plus $new_fp: $(accepted_ca_fingerprints | paste -sd, -)"
  sleep 10
done
log "PASS accepted CAs = Snapshot + $new_fp ($(paste -sd, - <<<"$want"))"

# Handshake check with a short-lived test leaf. The key exists only in a
# private temporary directory for the duration of the check.
work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -f "$work/leaf.crt" "$work/leaf.key" "$work/out.json"; rmdir "$work"' EXIT
vault_exec write -format=json "$PKI_MOUNT/issuer/$issuer/issue/$PKI_ROLE" \
  common_name=workers.temporal-proxy ttl=5m > "$work/out.json"
(umask 077
 jq -r '.data.certificate' "$work/out.json" > "$work/leaf.crt"
 jq -r '.data.private_key' "$work/out.json" > "$work/leaf.key")
rm -f "$work/out.json"

attempt=0
until temporal workflow count \
    --address "$TEMPORAL_CLOUD_ENDPOINT" --namespace "$TEMPORAL_NAMESPACE" \
    --tls-cert-path "$work/leaf.crt" --tls-key-path "$work/leaf.key" \
    --command-timeout 10s >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$(now_epoch)" -lt "$deadline" ] || fail "a leaf from $issuer is still rejected by $TEMPORAL_NAMESPACE after ${PROPAGATION_TIMEOUT}s"
  [ $((attempt % 6)) -ne 1 ] || log "  waiting for $TEMPORAL_NAMESPACE to accept leaves from $issuer"
  sleep 10
done
log "PASS a test leaf from $issuer is accepted by $TEMPORAL_NAMESPACE"

state_set phase trusted
state_set trust_verified_time "$(date -u +%FT%TZ)"
