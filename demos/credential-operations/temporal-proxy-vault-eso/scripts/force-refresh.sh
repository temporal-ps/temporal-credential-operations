#!/usr/bin/env bash
# Force an immediate ESO refresh of temporal-cloud-leaf in each client
# namespace, instead of waiting for the refresh interval. Used for an
# emergency rollover, and to shorten demos.
#
# Usage: ./scripts/force-refresh.sh [namespace ...]   (default: all client namespaces)
#
# ESO refreshes an ExternalSecret when its force-sync annotation changes.
#
# Verify (exits non-zero otherwise): each ExternalSecret's status.refreshTime
# advances and its Secret holds a different leaf serial than before.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools kubectl jq openssl

serial_of() {
  kc -n "$1" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -serial | cut -d= -f2
}

namespaces=("$@")
[ "${#namespaces[@]}" -gt 0 ] || namespaces=("${CLIENT_NAMESPACES[@]}")
for ns in "${namespaces[@]}"; do
  case " ${CLIENT_NAMESPACES[*]} " in *" $ns "*) ;; *) fail "unknown client namespace '$ns'" ;; esac
  before_time="$(kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.status.refreshTime}')"
  before_serial="$(serial_of "$ns")"
  kc -n "$ns" annotate externalsecret temporal-cloud-leaf force-sync="$(now_epoch)" --overwrite >/dev/null
  deadline=$(( $(now_epoch) + 60 ))
  until after_serial="$(serial_of "$ns")"; [ "$after_serial" != "$before_serial" ]; do
    [ "$(now_epoch)" -lt "$deadline" ] || fail "$ns: Secret unchanged 60s after force-sync"
    sleep 2
  done
  after_time="$(kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.status.refreshTime}')"
  log "PASS $ns: refreshed $before_time -> $after_time, leaf serial $before_serial -> $after_serial"
done
log "Proxies load the new leaves within kubelet sync plus one minute."
