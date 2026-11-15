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
LEAF_TTL_SECONDS=1800                   # role ttl=30m
ESO_REFRESH_SECONDS=600                 # ExternalSecret refreshInterval: 10m

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

# Load KEY=VALUE lines from the repository's .env.local without printing values.
load_env_local() {
  local env_file="${ENV_FILE:-$REPO_ROOT/.env.local}"
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

# Load the repository's .env.local when present, so every script sees the
# demo settings (see the repository-root .env.example).
if [ -f "${ENV_FILE:-$REPO_ROOT/.env.local}" ]; then load_env_local; fi

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

# --- Time --------------------------------------------------------------------
now_epoch() { date -u +%s; }
epoch_to_iso() { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }
# openssl "notAfter=Nov 16 03:20:51 2026 GMT" (value part) to epoch seconds.
openssl_date_to_epoch() {
  date -j -u -f '%b %e %T %Y %Z' "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}
