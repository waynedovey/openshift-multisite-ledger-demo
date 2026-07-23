#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT_DIR}/scripts/lib.sh"
for command in oc curl jq; do require_command "$command"; done

SITE_A_URL="$(route_url "$SITE_A_KUBECONFIG")"
SITE_B_URL="$(route_url "$SITE_B_KUBECONFIG")"
A_STATUS="$(curl -sk --max-time 15 "${SITE_A_URL}/api/status")"
B_STATUS="$(curl -sk --max-time 15 "${SITE_B_URL}/api/status")"
A_ACTIVE="$(jq -r '.active' <<<"$A_STATUS")"
B_ACTIVE="$(jq -r '.active' <<<"$B_STATUS")"
[[ "$A_ACTIVE" != "$B_ACTIVE" ]] || fail "Exactly one frontend must be active"

if [[ "$A_ACTIVE" == true ]]; then ACTIVE_URL="$SITE_A_URL"; ACTIVE_SITE="site-a"; else ACTIVE_URL="$SITE_B_URL"; ACTIVE_SITE="site-b"; fi
MESSAGE="verify-${ACTIVE_SITE}-$(date -u +%Y%m%dT%H%M%SZ)"

log "Creating a record through the active ${ACTIVE_SITE} frontend"
RESPONSE="$(curl -sk --fail-with-body --max-time 20 -H 'Content-Type: application/json' \
  -d "{\"message\":\"${MESSAGE}\"}" "${ACTIVE_URL}/api/entries")"
ENTRY_ID="$(jq -r '.id' <<<"$RESPONSE")"
[[ "$ENTRY_ID" =~ ^[0-9]+$ ]] || fail "The active frontend did not create a record: ${RESPONSE}"
ok "Created ledger entry ${ENTRY_ID} from ${ACTIVE_SITE}"

log "Waiting for the record to be visible through both local database endpoints"
for attempt in $(seq 1 60); do
  A_FOUND="$(curl -sk --max-time 10 "${SITE_A_URL}/api/entries" | jq --arg m "$MESSAGE" '[.[]|select(.message==$m)]|length' 2>/dev/null || echo 0)"
  B_FOUND="$(curl -sk --max-time 10 "${SITE_B_URL}/api/entries" | jq --arg m "$MESSAGE" '[.[]|select(.message==$m)]|length' 2>/dev/null || echo 0)"
  if [[ "$A_FOUND" -gt 0 && "$B_FOUND" -gt 0 ]]; then ok "Entry ${ENTRY_ID} is visible on Site A and the Site B replica"; break; fi
  (( attempt == 60 )) && fail "Entry ${ENTRY_ID} did not become visible on both sites"
  sleep 2
done
printf '\nSite A: %s\nSite B: %s\n' "$SITE_A_URL" "$SITE_B_URL"
