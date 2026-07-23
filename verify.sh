#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"
PASS=0; WARN=0; FAIL=0
pass(){ echo "[PASS] $*"; PASS=$((PASS+1)); }
warn_check(){ echo "[WARN] $*"; WARN=$((WARN+1)); }
fail_check(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
for command in oc curl jq; do require_command "$command"; done

check_site() {
  local label="$1" kubeconfig="$2" db_name="$3"
  echo; echo "=== ${label} ==="
  if oc --kubeconfig "$kubeconfig" get namespace "$NAMESPACE" >/dev/null 2>&1; then pass "Namespace exists"; else fail_check "Namespace missing"; return; fi
  site_status="$(oc --kubeconfig "$kubeconfig" get site.skupper.io -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[0].status.status//"Missing"')"
  [[ "$site_status" == Ready ]] && pass "Service Interconnect Site Ready" || fail_check "Service Interconnect Site status: ${site_status}"
  db_ready="$(oc --kubeconfig "$kubeconfig" get cluster.postgresql.cnpg.io "$db_name" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.readyInstances//0')"
  [[ "$db_ready" -eq 2 ]] && pass "CloudNativePG ${db_name} is 2/2 Ready" || fail_check "CloudNativePG ${db_name} ready instances: ${db_ready}"
  secret_ready="$(oc --kubeconfig "$kubeconfig" get externalsecret.external-secrets.io ledger-db-app -n "$NAMESPACE" -o json 2>/dev/null | jq '[.status.conditions[]?|select(.type=="Ready" and .status=="True")]|length')"
  [[ "$secret_ready" -gt 0 ]] && pass "Vault application secret synchronized" || fail_check "ExternalSecret ledger-db-app not Ready"
  role="$(oc --kubeconfig "$kubeconfig" get deployment ledger-web -n "$NAMESPACE" -o json | jq -r '.spec.template.metadata.labels["demo.redhat.com/frontend-role"]//"missing"')"
  [[ "$role" == active || "$role" == standby ]] && pass "Frontend role is ${role}" || fail_check "Frontend role missing"
  url="$(route_url "$kubeconfig" 2>/dev/null || true)"
  if [[ -n "$url" ]] && curl -sk --max-time 15 "${url}/healthz" | jq -e '.status=="ok"' >/dev/null 2>&1; then pass "Web frontend reachable at ${url}"; else fail_check "Web frontend is not reachable"; fi
}

check_site "Site A — ${SITE_A_CLUSTER}" "$SITE_A_KUBECONFIG" ledger-db
check_site "Site B — ${SITE_B_CLUSTER}" "$SITE_B_KUBECONFIG" ledger-db-replica

echo; echo "=== Cross-site state ==="
link_status="$(oc --kubeconfig "$SITE_B_KUBECONFIG" get link.skupper.io ledger-link-to-site-a -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.status//"Missing"')"
[[ "$link_status" == Ready ]] && pass "Service Interconnect Link is Ready" || fail_check "Link status: ${link_status}"
A_ROLE="$(oc --kubeconfig "$SITE_A_KUBECONFIG" get deployment ledger-web -n "$NAMESPACE" -o json | jq -r '.spec.template.metadata.labels["demo.redhat.com/frontend-role"]//"missing"')"
B_ROLE="$(oc --kubeconfig "$SITE_B_KUBECONFIG" get deployment ledger-web -n "$NAMESPACE" -o json | jq -r '.spec.template.metadata.labels["demo.redhat.com/frontend-role"]//"missing"')"
if [[ "$A_ROLE:$B_ROLE" == active:standby || "$A_ROLE:$B_ROLE" == standby:active ]]; then pass "Exactly one web frontend is active"; else fail_check "Frontend roles are Site A=${A_ROLE}, Site B=${B_ROLE}"; fi

recovery_pod="$(oc --kubeconfig "$SITE_B_KUBECONFIG" get pod -n "$NAMESPACE" -l cnpg.io/cluster=ledger-db-replica,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$recovery_pod" ]]; then
  recovery="$(oc --kubeconfig "$SITE_B_KUBECONFIG" exec -n "$NAMESPACE" "$recovery_pod" -c postgres -- psql -U postgres -tAc 'select pg_is_in_recovery();' 2>/dev/null | tr -d '[:space:]')"
  [[ "$recovery" == t ]] && pass "Site B PostgreSQL is in recovery mode" || fail_check "Site B PostgreSQL is not in recovery"
else fail_check "Could not locate Site B PostgreSQL pod"; fi

if "${ROOT_DIR}/scripts/test-demo.sh"; then pass "Cross-site record test passed"; else fail_check "Cross-site record test failed"; fi

echo; echo "=== Summary ==="; echo "PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
