#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-multisite-ledger}"
SITE_A_CLUSTER="${SITE_A_CLUSTER:-cluster-pwv6d}"
SITE_B_CLUSTER="${SITE_B_CLUSTER:-cluster-7b6lh}"
SITE_A_KUBECONFIG="${SITE_A_KUBECONFIG:-${ROOT_DIR}/.work/kubeconfigs/${SITE_A_CLUSTER}.kubeconfig}"
SITE_B_KUBECONFIG="${SITE_B_KUBECONFIG:-${ROOT_DIR}/.work/kubeconfigs/${SITE_B_CLUSTER}.kubeconfig}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault-demo}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }

find_vault_pod() {
  local kubeconfig="$1"
  oc --kubeconfig "$kubeconfig" get pods -n "$VAULT_NAMESPACE" -o json 2>/dev/null |
    jq -r '.items[] | select(.status.phase=="Running") | select(.metadata.name|startswith("vault")) | .metadata.name' |
    head -1
}

vault_put() {
  local kubeconfig="$1" path="$2"
  shift 2
  local pod
  pod="$(find_vault_pod "$kubeconfig")"
  [[ -n "$pod" ]] || fail "No running Vault pod found in ${VAULT_NAMESPACE}"
  oc --kubeconfig "$kubeconfig" exec -n "$VAULT_NAMESPACE" "$pod" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

vault_delete() {
  local kubeconfig="$1" path="$2"
  local pod
  pod="$(find_vault_pod "$kubeconfig")"
  [[ -n "$pod" ]] || return 0
  oc --kubeconfig "$kubeconfig" exec -n "$VAULT_NAMESPACE" "$pod" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv metadata delete "secret/${path}" >/dev/null 2>&1 || true
}

route_url() {
  local kubeconfig="$1"
  oc --kubeconfig "$kubeconfig" get route ledger-web -n "$NAMESPACE" -o jsonpath='https://{.spec.host}'
}
