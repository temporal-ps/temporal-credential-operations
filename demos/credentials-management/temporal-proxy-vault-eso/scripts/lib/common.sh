#!/usr/bin/env bash
# Shared settings and helpers for the Temporal Proxy + Vault PKI + ESO demo.
# Source this file; do not execute it.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/../../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-tco-proxy-vault-eso}"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
CLIENT_NAMESPACES=(workers callers)
OBSERVABILITY_NAMESPACE="observability"
VAULT_NAMESPACE="vault"
ESO_NAMESPACE="external-secrets"

# Helm charts, pinned.
VAULT_CHART_REPO="https://helm.releases.hashicorp.com"
VAULT_CHART_VERSION="0.34.1"            # Vault 2.0.4
ESO_CHART_REPO="https://charts.external-secrets.io"
ESO_CHART_VERSION="2.15.0"              # External Secrets Operator v2.15.0

# Vault PKI layout. See the spec's Components section.
PKI_MOUNT="pki-temporal"
PKI_ROLE="temporal-client"

# Local, gitignored state: exported issuer certificates (public only).
STATE_DIR="$DEMO_DIR/.state"
ROTATION_STATE_CONFIGMAP="rotation-state"

# Temporal Proxy is built from source at a pinned commit because TLS hot
# reload is not yet in a tagged release.
TEMPORAL_PROXY_REPO="${TEMPORAL_PROXY_REPO:-https://github.com/temporalio/temporal-proxy.git}"
TEMPORAL_PROXY_REF="${TEMPORAL_PROXY_REF:-64fae49}"
TEMPORAL_PROXY_IMAGE="temporal-proxy:${TEMPORAL_PROXY_REF}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || fail "required tool not found: $t"
  done
}

# Load KEY=VALUE lines from a file without printing values.
load_kv_file() {
  local env_file="$1"
  [ -f "$env_file" ] || fail "missing $env_file"
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if [[ "$value" == \"*\" ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    export "$key=$value"
  done < "$env_file"
}

# The repository's .env.local (see the repository-root .env.example).
load_env_local() { load_kv_file "${ENV_FILE:-$REPO_ROOT/.env.local}"; }

# Demo timing settings, then .env.local, which may override them.
SETTINGS_FILE="$DEMO_DIR/demo-settings.env"
load_kv_file "$SETTINGS_FILE"
if [ -f "${ENV_FILE:-$REPO_ROOT/.env.local}" ]; then load_env_local; fi

# Duration with an s, m, or h suffix (or plain seconds) to seconds.
duration_seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *[!0-9]*|"") fail "not a duration: '$1' (use s, m, or h)" ;;
    *) echo "$1" ;;
  esac
}

ESO_REFRESH_SECONDS="$(duration_seconds "$ESO_REFRESH_INTERVAL")"
LEAF_TTL_SECONDS="$(duration_seconds "$LEAF_TTL")"
GATE_SKEW_SECONDS="$GATE_CLOCK_SKEW_SECONDS"

# Resolve a path from .env.local: absolute as given, otherwise relative to the
# repository root.
repo_path() {
  case "$1" in
    "") ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

# Bootstrap (manually generated) client CA certificate and key, gitignored.
MANUAL_CERT_FILE="$(repo_path "${TEMPORAL_DEMO_CA_CERT_FILE:-}")"
MANUAL_KEY_FILE="$(repo_path "${TEMPORAL_DEMO_CA_KEY_FILE:-}")"

require_demo_ca() {
  [ -n "$MANUAL_CERT_FILE" ] || fail "TEMPORAL_DEMO_CA_CERT_FILE is not set in .env.local"
  [ -n "$MANUAL_KEY_FILE" ] || fail "TEMPORAL_DEMO_CA_KEY_FILE is not set in .env.local"
  [ -f "$MANUAL_CERT_FILE" ] || fail "missing $MANUAL_CERT_FILE (TEMPORAL_DEMO_CA_CERT_FILE)"
  [ -f "$MANUAL_KEY_FILE" ] || fail "missing $MANUAL_KEY_FILE (TEMPORAL_DEMO_CA_KEY_FILE)"
}

# Derive the Temporal Cloud endpoint and fully qualified Namespace from
# TEMPORAL_DEMO_NAMESPACE_ADDRESS (<namespace>.<account>.tmprl.cloud:7233).
resolve_target() {
  load_env_local
  : "${TEMPORAL_DEMO_NAMESPACE_ADDRESS:?TEMPORAL_DEMO_NAMESPACE_ADDRESS is not set in .env.local}"
  TEMPORAL_CLOUD_ENDPOINT="$TEMPORAL_DEMO_NAMESPACE_ADDRESS"
  local host="${TEMPORAL_CLOUD_ENDPOINT%%:*}"
  TEMPORAL_NAMESPACE="${host%.tmprl.cloud}"
  [ "$TEMPORAL_NAMESPACE" != "$host" ] || fail "target is not a <namespace>.<account>.tmprl.cloud endpoint"
  export TEMPORAL_CLOUD_ENDPOINT TEMPORAL_NAMESPACE
}

# Print a certificate's subject, issuer, serial, and NotAfter (never key material).
describe_cert() {
  openssl x509 -noout -subject -issuer -serial -enddate
}

# --- Vault -------------------------------------------------------------------
# Runs the Vault CLI inside the dev-mode server Pod, so the operator needs no
# local Vault install. The dev root token is a demo-only value: Vault is not
# exposed outside the cluster. Production uses the operator's own Vault login.
vault_exec() {
  kc -n "$VAULT_NAMESPACE" exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault "$@"
}

# --- Temporal Cloud ----------------------------------------------------------
# tcld reads its API key from TEMPORAL_CLOUD_API_KEY. Export it from
# .env.local for this process only; never print it or place it in the cluster.
use_ops_api_key() {
  : "${TEMPORAL_CLOUD_OPS_API_KEY:?TEMPORAL_CLOUD_OPS_API_KEY is not set in .env.local}"
  export TEMPORAL_CLOUD_API_KEY="$TEMPORAL_CLOUD_OPS_API_KEY"
}

# Accepted client CA fingerprints (SHA-1, lowercase hex, as tcld reports them),
# one per line, sorted.
accepted_ca_fingerprints() {
  tcld namespace accepted-client-ca list -n "$TEMPORAL_NAMESPACE" | jq -r '.[].fingerprint' | sort
}

# SHA-1 fingerprint of a PEM certificate on stdin, in tcld's format.
cert_sha1() {
  openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

# --- Rollover state ----------------------------------------------------------
# A ConfigMap in the vault namespace, so any operator can resume a rollover.
state_get() {
  kc -n "$VAULT_NAMESPACE" get configmap "$ROTATION_STATE_CONFIGMAP" \
    -o jsonpath="{.data.$1}" 2>/dev/null || true
}

state_set() {
  local key="$1" value="$2"
  kc -n "$VAULT_NAMESPACE" get configmap "$ROTATION_STATE_CONFIGMAP" >/dev/null 2>&1 \
    || kc -n "$VAULT_NAMESPACE" create configmap "$ROTATION_STATE_CONFIGMAP" >/dev/null
  kc -n "$VAULT_NAMESPACE" patch configmap "$ROTATION_STATE_CONFIGMAP" --type merge \
    -p "$(jq -cn --arg k "$key" --arg v "$value" '{data: {($k): $v}}')" >/dev/null
}

# --- Prometheus --------------------------------------------------------------
prom_query() {
  kc -n "$OBSERVABILITY_NAMESPACE" exec deploy/prometheus -c prometheus -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')"
}

# Any Prometheus API path, e.g. "rules".
prom_query_api() {
  kc -n "$OBSERVABILITY_NAMESPACE" exec deploy/prometheus -c prometheus -- \
    wget -qO- "http://localhost:9090/api/v1/$1"
}

# Ready proxy Pods across client namespaces, one "<namespace>/<pod>" per line.
ready_proxy_pods() {
  local ns
  for ns in "${CLIENT_NAMESPACES[@]}"; do
    kc -n "$ns" get pods -l app.kubernetes.io/name=temporal-proxy -o json \
      | jq -r '.items[] | select(.metadata.deletionTimestamp == null)
          | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
          | "\(.metadata.namespace)/\(.metadata.name)"'
  done
}

# --- ESO -----------------------------------------------------------------------
# Set each client namespace's ExternalSecret refreshInterval from
# ESO_REFRESH_INTERVAL. Call after any kubectl apply of k8s/eso-clients, which
# carries the manifest default. Skips namespaces without one.
apply_eso_refresh_interval() {
  local ns got
  for ns in "${CLIENT_NAMESPACES[@]}"; do
    kc -n "$ns" get externalsecret temporal-cloud-leaf >/dev/null 2>&1 || {
      log "INFO $ns: no ExternalSecret yet"; continue; }
    kc -n "$ns" patch externalsecret temporal-cloud-leaf --type merge \
      -p "{\"spec\":{\"refreshInterval\":\"$ESO_REFRESH_INTERVAL\"}}" >/dev/null
    got="$(kc -n "$ns" get externalsecret temporal-cloud-leaf -o jsonpath='{.spec.refreshInterval}')"
    [ "$(duration_seconds "$got")" = "$ESO_REFRESH_SECONDS" ] \
      || fail "$ns: ExternalSecret refreshInterval reads back '$got', expected $ESO_REFRESH_INTERVAL"
    log "PASS $ns: ExternalSecret refreshInterval $got"
  done
}

# --- Vault PKI issuers -------------------------------------------------------
# The issuer the temporal-client role signs with.
role_issuer() {
  vault_exec read -format=json "$PKI_MOUNT/roles/$PKI_ROLE" | jq -r '.data.issuer_ref'
}

# PEM certificate of a Vault issuer.
issuer_cert() {
  vault_exec read -format=json "$PKI_MOUNT/issuer/$1" | jq -r '.data.certificate'
}

# --- Retirement gate -----------------------------------------------------------
# Evaluates the gate against the switch recorded in rotation-state and prints
# one PASS or FAIL line per check. Returns non-zero if any check fails.
#
#   1. Every proxy Deployment is fully Ready, and every Ready proxy Pod reports
#      a loaded leaf. (Prometheus keeps a terminated Pod's series for a few
#      minutes, so only series from currently Ready Pods count.)
#   2. Every loaded leaf was issued after the switch:
#      NotAfter >= switch + leaf TTL - skew.
#   3. No TLS reload failures in the last 15 minutes.
#   4. Each namespace's Secret holds a leaf signed by the new issuer.
gate_evaluate() {
  local switch_epoch issuer pem ns ready want expected=0 rc=0
  switch_epoch="$(state_get switch_epoch)"
  issuer="$(state_get new_issuer)"
  pem="$STATE_DIR/$issuer.pem"
  [ -n "$switch_epoch" ] || { log "FAIL gate: no switch recorded"; return 1; }
  [ -f "$pem" ] || { log "FAIL gate: missing $pem"; return 1; }

  for ns in "${CLIENT_NAMESPACES[@]}"; do
    ready="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.status.readyReplicas}')"
    want="$(kc -n "$ns" get deploy temporal-proxy -o jsonpath='{.spec.replicas}')"
    if [ "${ready:-0}" != "$want" ]; then
      log "FAIL gate: $ns/temporal-proxy ready ${ready:-0}/$want"; rc=1
    fi
    expected=$((expected + want))
  done

  local ready_pods series count min stale
  ready_pods="$(ready_proxy_pods | jq -R . | jq -sc .)"
  series="$(prom_query 'tmprl_proxy_tls_cert_expiry_timestamp_seconds{file="cert"}'     | jq --argjson ready "$ready_pods"       '[.data.result[] | select(("\(.metric.namespace)/\(.metric.pod)") as $p | $ready | index($p))]')"
  count="$(jq 'length' <<<"$series")"
  if [ "$count" -eq "$expected" ]; then
    log "PASS gate: $count of $expected proxies report a loaded leaf"
  else
    log "FAIL gate: $count of $expected proxies report a loaded leaf"; rc=1
  fi

  min=$((switch_epoch + LEAF_TTL_SECONDS - GATE_SKEW_SECONDS))
  stale="$(jq -r --argjson min "$min" '.[] | select((.value[1]|tonumber) < $min)
    | "\(.metric.namespace)/\(.metric.pod) leaf NotAfter \(.value[1]|tonumber|floor|todate)"' <<<"$series")"
  if [ -z "$stale" ]; then
    log "PASS gate: every loaded leaf was issued after the switch"
  else
    while IFS= read -r line; do log "FAIL gate: pre-switch leaf on $line"; done <<<"$stale"
    rc=1
  fi

  local failures
  failures="$(prom_query 'sum(increase(tmprl_proxy_tls_reloads_total{result="failure"}[15m])) or vector(0)'     | jq -r '.data.result[0].value[1] | tonumber | floor')"
  if [ "$failures" = "0" ]; then
    log "PASS gate: no TLS reload failures in the last 15 minutes"
  else
    log "FAIL gate: $failures TLS reload failures in the last 15 minutes"; rc=1
  fi

  local crt
  for ns in "${CLIENT_NAMESPACES[@]}"; do
    crt="$(kc -n "$ns" get secret temporal-cloud-leaf -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -n "$crt" ] && openssl verify -CAfile "$pem" <(printf '%s\n' "$crt") >/dev/null 2>&1; then
      log "PASS gate: $ns Secret holds a leaf signed by $issuer"
    else
      log "FAIL gate: $ns Secret does not hold a leaf signed by $issuer"; rc=1
    fi
  done
  return "$rc"
}

# --- Grafana annotations ---------------------------------------------------------
# Posts an org-wide annotation tagged "rotation" (shown on the dashboard).
# Runs inside the Grafana Pod with its own admin credential, which never
# leaves the cluster. Best effort: a failure is reported, not fatal.
grafana_annotate() {
  local text="$1" body
  body="$(jq -cn --arg t "$text" --argjson ms "$(( $(now_epoch) * 1000 ))"     '{time: $ms, tags: ["rotation"], text: $t}')"
  kc -n "$OBSERVABILITY_NAMESPACE" exec deploy/grafana -c grafana -- sh -c \
    'wget -qO- --header "Content-Type: application/json" --post-data "$1" "http://admin:$GF_SECURITY_ADMIN_PASSWORD@localhost:3000/api/annotations"' \
    _ "$body" >/dev/null 2>&1 || log "  (could not post Grafana annotation: $text)"
}

# --- Time --------------------------------------------------------------------
now_epoch() { date -u +%s; }
epoch_to_iso() { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }
# openssl "notAfter=Nov 16 03:20:51 2026 GMT" (value part) to epoch seconds.
openssl_date_to_epoch() {
  date -j -u -f '%b %e %T %Y %Z' "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}
