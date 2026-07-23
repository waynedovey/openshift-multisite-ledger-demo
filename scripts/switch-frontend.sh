#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

TARGET="${1:-}"
case "$TARGET" in
  site-a)
    TARGET_KC="$SITE_A_KUBECONFIG"; SOURCE_KC="$SITE_B_KUBECONFIG"
    TARGET_NAME="Site A"; SOURCE_NAME="Site B"
    ;;
  site-b)
    TARGET_KC="$SITE_B_KUBECONFIG"; SOURCE_KC="$SITE_A_KUBECONFIG"
    TARGET_NAME="Site B"; SOURCE_NAME="Site A"
    ;;
  *) echo "Usage: $0 site-a|site-b" >&2; exit 2 ;;
esac

for command in oc curl jq; do require_command "$command"; done

patch_role() {
  local kubeconfig="$1" role="$2"
  oc --kubeconfig "$kubeconfig" patch deployment ledger-web -n "$NAMESPACE" --type=merge -p "{
    \"spec\": {\"template\": {\"metadata\": {\"labels\": {\"demo.redhat.com/frontend-role\": \"${role}\"}}}}
  }" >/dev/null
  oc --kubeconfig "$kubeconfig" rollout status deployment/ledger-web -n "$NAMESPACE" --timeout=10m
}

log "Putting ${SOURCE_NAME} into STANDBY"
patch_role "$SOURCE_KC" standby

log "Activating ${TARGET_NAME}"
patch_role "$TARGET_KC" active

TARGET_URL="$(route_url "$TARGET_KC")"
SOURCE_URL="$(route_url "$SOURCE_KC")"

log "Confirming the active frontend can reach the writable Site A PostgreSQL primary"
for attempt in $(seq 1 30); do
  status="$(curl -sk --max-time 10 "${TARGET_URL}/api/status" 2>/dev/null || true)"
  if jq -e '.active==true and .write_database.in_recovery==false' <<<"$status" >/dev/null 2>&1; then break; fi
  (( attempt == 30 )) && fail "${TARGET_NAME} is active but its writable PostgreSQL path was not verified"
  sleep 3
done

cat <<RESULT

Frontend switch complete.

ACTIVE:  ${TARGET_NAME} — ${TARGET_URL}
STANDBY: ${SOURCE_NAME} — ${SOURCE_URL}

PostgreSQL remains primary on Site A.
An active Site B frontend writes to Site A through Service Interconnect.
RESULT
