#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

REPO_URL=""
REVISION="main"
SITE_A_KC_EXPLICIT=false
SITE_B_KC_EXPLICIT=false

usage() {
  cat <<USAGE
Usage: $0 --repo-url URL [options]

Options:
  --revision REVISION              Git revision, default: main
  --site-a CLUSTER                 Argo CD cluster name, default: cluster-pwv6d
  --site-b CLUSTER                 Argo CD cluster name, default: cluster-7b6lh
  --site-a-kubeconfig PATH         Site A kubeconfig
  --site-b-kubeconfig PATH         Site B kubeconfig
  --vault-token TOKEN              Existing Vault token, default: root
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --site-a) SITE_A_CLUSTER="$2"; shift 2 ;;
    --site-b) SITE_B_CLUSTER="$2"; shift 2 ;;
    --site-a-kubeconfig) SITE_A_KUBECONFIG="$2"; SITE_A_KC_EXPLICIT=true; shift 2 ;;
    --site-b-kubeconfig) SITE_B_KUBECONFIG="$2"; SITE_B_KC_EXPLICIT=true; shift 2 ;;
    --vault-token) VAULT_TOKEN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$REPO_URL" ]] || { usage; fail "--repo-url is required"; }
$SITE_A_KC_EXPLICIT || SITE_A_KUBECONFIG="${ROOT_DIR}/.work/kubeconfigs/${SITE_A_CLUSTER}.kubeconfig"
$SITE_B_KC_EXPLICIT || SITE_B_KUBECONFIG="${ROOT_DIR}/.work/kubeconfigs/${SITE_B_CLUSTER}.kubeconfig"

for command in oc jq sed openssl curl; do require_command "$command"; done
[[ -f "$SITE_A_KUBECONFIG" ]] || fail "Site A kubeconfig not found: $SITE_A_KUBECONFIG"
[[ -f "$SITE_B_KUBECONFIG" ]] || fail "Site B kubeconfig not found: $SITE_B_KUBECONFIG"
mkdir -p "${ROOT_DIR}/.work"

log "Checking RHACM hub and existing OpenShift GitOps"
oc whoami >/dev/null
oc get crd applications.argoproj.io >/dev/null
oc get namespace openshift-gitops >/dev/null
ok "Hub and Argo CD are reachable"

log "Checking existing operators and shared Vault integration"
for item in "${SITE_A_CLUSTER}|${SITE_A_KUBECONFIG}" "${SITE_B_CLUSTER}|${SITE_B_KUBECONFIG}"; do
  cluster="${item%%|*}"
  kubeconfig="${item#*|}"
  oc --kubeconfig "$kubeconfig" get crd clusters.postgresql.cnpg.io >/dev/null
  oc --kubeconfig "$kubeconfig" get crd sites.skupper.io >/dev/null
  oc --kubeconfig "$kubeconfig" get crd networkobservers.observability.skupper.io >/dev/null
  oc --kubeconfig "$kubeconfig" get crd externalsecrets.external-secrets.io >/dev/null
  oc --kubeconfig "$kubeconfig" get clustersecretstore.external-secrets.io demo-vault >/dev/null
  ready="$(oc --kubeconfig "$kubeconfig" get clustersecretstore.external-secrets.io demo-vault -o json | jq '[.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length')"
  [[ "$ready" -gt 0 ]] || fail "ClusterSecretStore/demo-vault is not Ready on ${cluster}"
  ok "${cluster}: required CRDs and demo-vault are ready"
done

log "Writing application credentials to the existing Vault instances"

[[ -n "${VAULT_TOKEN:-}" ]] || fail   "Vault token not found. Add VAULT_TOKEN to .work/demo.env or pass --vault-token."

DB_PASSWORD="$(openssl rand -base64 30 | tr -d '\n')"
vault_put "$SITE_A_KUBECONFIG" multisite-ledger/app username=ledger password="$DB_PASSWORD" database=ledger
vault_put "$SITE_B_KUBECONFIG" multisite-ledger/app username=ledger password="$DB_PASSWORD" database=ledger
ok "Vault paths seeded on Site A and Site B"

log "Creating the two Argo CD Applications"
sed \
  -e "s|__REPO_URL__|${REPO_URL}|g" \
  -e "s|__REVISION__|${REVISION}|g" \
  -e "s|__SITE_A_CLUSTER__|${SITE_A_CLUSTER}|g" \
  -e "s|__SITE_B_CLUSTER__|${SITE_B_CLUSTER}|g" \
  "${ROOT_DIR}/hub/applications-template.yaml" > "${ROOT_DIR}/.work/applications.yaml"
oc apply -f "${ROOT_DIR}/.work/applications.yaml"

log "Waiting for namespaces, application secrets, and Service Interconnect Sites"
for kubeconfig in "$SITE_A_KUBECONFIG" "$SITE_B_KUBECONFIG"; do
  for attempt in $(seq 1 120); do
    oc --kubeconfig "$kubeconfig" get namespace "$NAMESPACE" >/dev/null 2>&1 && break
    (( attempt == 120 )) && fail "Namespace ${NAMESPACE} was not created"
    sleep 5
  done
  oc --kubeconfig "$kubeconfig" wait externalsecret.external-secrets.io/ledger-db-app \
    -n "$NAMESPACE" --for=condition=Ready --timeout=10m
  for attempt in $(seq 1 120); do
    count="$(oc --kubeconfig "$kubeconfig" get site.skupper.io -n "$NAMESPACE" -o json 2>/dev/null | jq '[.items[] | select(.status.status=="Ready")] | length' || echo 0)"
    [[ "$count" -ge 1 ]] && break
    (( attempt == 120 )) && fail "Service Interconnect Site did not become Ready"
    sleep 5
  done
done
ok "Both application Sites are Ready"

log "Waiting for the Site A PostgreSQL primary"
oc --kubeconfig "$SITE_A_KUBECONFIG" wait cluster.postgresql.cnpg.io/ledger-db \
  -n "$NAMESPACE" --for=condition=Ready --timeout=20m
for attempt in $(seq 1 120); do
  if oc --kubeconfig "$SITE_A_KUBECONFIG" get secret ledger-db-ca ledger-db-replication -n "$NAMESPACE" >/dev/null 2>&1; then break; fi
  (( attempt == 120 )) && fail "CloudNativePG replication Secrets were not created"
  sleep 5
done
ok "Site A PostgreSQL is Ready"

log "Copying the CloudNativePG replication identity into Site B Vault"
CA_B64="$(oc --kubeconfig "$SITE_A_KUBECONFIG" get secret ledger-db-ca -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}')"
CERT_B64="$(oc --kubeconfig "$SITE_A_KUBECONFIG" get secret ledger-db-replication -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}')"
KEY_B64="$(oc --kubeconfig "$SITE_A_KUBECONFIG" get secret ledger-db-replication -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}')"
[[ -n "$CA_B64" && -n "$CERT_B64" && -n "$KEY_B64" ]] || fail "Could not read replication certificate data"
vault_put "$SITE_B_KUBECONFIG" multisite-ledger/replication ca_crt_b64="$CA_B64" tls_crt_b64="$CERT_B64" tls_key_b64="$KEY_B64"
oc --kubeconfig "$SITE_B_KUBECONFIG" wait externalsecret.external-secrets.io/ledger-db-ca -n "$NAMESPACE" --for=condition=Ready --timeout=10m
oc --kubeconfig "$SITE_B_KUBECONFIG" wait externalsecret.external-secrets.io/ledger-db-replication -n "$NAMESPACE" --for=condition=Ready --timeout=10m
ok "Site B replication Secrets are Ready"

log "Ensuring the existing Service Interconnect GrantServer is available"
GRANT_SERVER_READY=false
for attempt in $(seq 1 24); do
  if oc --kubeconfig "$SITE_A_KUBECONFIG" get service skupper-grant-server -n openshift-operators >/dev/null 2>&1 && \
     oc --kubeconfig "$SITE_A_KUBECONFIG" get route skupper-grant-server-https -n openshift-operators >/dev/null 2>&1; then
    GRANT_SERVER_READY=true
    break
  fi
  sleep 5
done
if [[ "$GRANT_SERVER_READY" != true ]]; then
  warn "GrantServer was absent; restarting the existing Skupper controller once"
  oc --kubeconfig "$SITE_A_KUBECONFIG" rollout restart deployment/skupper-controller -n openshift-operators
  oc --kubeconfig "$SITE_A_KUBECONFIG" rollout status deployment/skupper-controller -n openshift-operators --timeout=5m
  for attempt in $(seq 1 60); do
    if oc --kubeconfig "$SITE_A_KUBECONFIG" get service skupper-grant-server -n openshift-operators >/dev/null 2>&1 && \
       oc --kubeconfig "$SITE_A_KUBECONFIG" get route skupper-grant-server-https -n openshift-operators >/dev/null 2>&1; then
      GRANT_SERVER_READY=true
      break
    fi
    sleep 5
  done
fi
[[ "$GRANT_SERVER_READY" == true ]] || fail "GrantServer Service and Route are unavailable"
ok "GrantServer Service and Route are available"

log "Creating a fresh Service Interconnect link from Site B to Site A"
TOKEN_NAME="ledger-link-to-site-a"
GRANT_NAME="ledger-grant-$(date +%s)"
oc --kubeconfig "$SITE_B_KUBECONFIG" delete accesstoken.skupper.io "$TOKEN_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null
oc --kubeconfig "$SITE_B_KUBECONFIG" delete link.skupper.io "$TOKEN_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null
oc --kubeconfig "$SITE_A_KUBECONFIG" apply -f - <<GRANT
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: ${GRANT_NAME}
  namespace: ${NAMESPACE}
spec:
  redemptionsAllowed: 1
  expirationWindow: 30m
GRANT
oc --kubeconfig "$SITE_A_KUBECONFIG" wait accessgrant.skupper.io/"$GRANT_NAME" -n "$NAMESPACE" --for=condition=Ready --timeout=5m
oc --kubeconfig "$SITE_A_KUBECONFIG" get accessgrant.skupper.io "$GRANT_NAME" -n "$NAMESPACE" -o json |
  jq --arg name "$TOKEN_NAME" --arg namespace "$NAMESPACE" '{apiVersion:"skupper.io/v2alpha1",kind:"AccessToken",metadata:{name:$name,namespace:$namespace},spec:{url:.status.url,code:.status.code,ca:.status.ca}}' \
  > "${ROOT_DIR}/.work/access-token.json"
oc --kubeconfig "$SITE_B_KUBECONFIG" apply -f "${ROOT_DIR}/.work/access-token.json"
for attempt in $(seq 1 120); do
  token_ready="$(oc --kubeconfig "$SITE_B_KUBECONFIG" get accesstoken.skupper.io "$TOKEN_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '(.status.redeemed==true) and (.status.status=="Ready")' || echo false)"
  link_ready="$(oc --kubeconfig "$SITE_B_KUBECONFIG" get link.skupper.io "$TOKEN_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.status=="Ready"' || echo false)"
  [[ "$token_ready" == true && "$link_ready" == true ]] && break
  if (( attempt == 120 )); then
    oc --kubeconfig "$SITE_B_KUBECONFIG" get accesstoken,link -n "$NAMESPACE" || true
    fail "Service Interconnect link did not become Ready"
  fi
  sleep 5
done
ok "Service Interconnect Link is Ready"

log "Waiting for the Site B PostgreSQL streaming replica"
oc --kubeconfig "$SITE_B_KUBECONFIG" wait cluster.postgresql.cnpg.io/ledger-db-replica \
  -n "$NAMESPACE" --for=condition=Ready --timeout=30m
ok "Site B PostgreSQL replica is Ready"

log "Waiting for both web frontends"
oc --kubeconfig "$SITE_A_KUBECONFIG" rollout status deployment/ledger-web -n "$NAMESPACE" --timeout=15m
oc --kubeconfig "$SITE_B_KUBECONFIG" rollout status deployment/ledger-web -n "$NAMESPACE" --timeout=15m

log "Waiting for Argo CD health"
for app in multisite-ledger-site-a multisite-ledger-site-b; do
  for attempt in $(seq 1 120); do
    state="$(oc get applications.argoproj.io "$app" -n openshift-gitops -o json 2>/dev/null | jq -r '(.status.sync.status//"")+"/"+(.status.health.status//"")' || true)"
    [[ "$state" == "Synced/Healthy" ]] && break
    if (( attempt == 120 )); then warn "${app} is ${state}; workloads are running but Argo CD has not reported Synced/Healthy"; fi
    sleep 5
  done
done

SITE_A_URL="$(route_url "$SITE_A_KUBECONFIG")"
SITE_B_URL="$(route_url "$SITE_B_KUBECONFIG")"
cat <<RESULT

Deployment complete.

Site A ACTIVE:  ${SITE_A_URL}
Site B STANDBY: ${SITE_B_URL}

Switch to Site B:
  ./scripts/switch-frontend.sh site-b

Verify:
  ./verify.sh
RESULT
