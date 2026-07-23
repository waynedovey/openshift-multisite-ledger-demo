#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"
for command in oc jq; do require_command "$command"; done

log "Deleting only the Multi-Site Ledger Argo CD Applications"
oc delete applications.argoproj.io multisite-ledger-site-a multisite-ledger-site-b -n openshift-gitops --ignore-not-found
log "Deleting the application namespace from both managed clusters"
oc --kubeconfig "$SITE_A_KUBECONFIG" delete namespace "$NAMESPACE" --ignore-not-found --wait=false
oc --kubeconfig "$SITE_B_KUBECONFIG" delete namespace "$NAMESPACE" --ignore-not-found --wait=false
log "Deleting only this demo's Vault paths"
vault_delete "$SITE_A_KUBECONFIG" multisite-ledger/app
vault_delete "$SITE_B_KUBECONFIG" multisite-ledger/app
vault_delete "$SITE_B_KUBECONFIG" multisite-ledger/replication
rm -f "${ROOT_DIR}/.work/access-token.json" "${ROOT_DIR}/.work/applications.yaml"
cat <<RESULT

Cleanup requested. The operators, Vault deployment, ClusterSecretStore/demo-vault, and existing Bookinfo demo were not changed.
RESULT
