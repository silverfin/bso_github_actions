#!/usr/bin/env bash
# Authorize a Silverfin partner api_key against an isolated throwaway HOME,
# then push the resulting config.json straight to a market repo's
# PARTNER_CONFIG_JSON_<partner_id> GitHub secret. Cleans up after itself.
#
# Usage:
#   ./authorize-partner-secret.sh <partner_id> <market> [host]
#
#   <market> is either a short code (nl, be, lu, uk) or a full "owner/repo".
#
# Examples:
#   ./authorize-partner-secret.sh 2 nl
#   ./authorize-partner-secret.sh 11 lu
#   ./authorize-partner-secret.sh 1 silverfin/be_market
#
# Prompts for the api_key with hidden input (never as an argv, so it never
# lands in shell history). Re-run once per partner after each staging reset.

set -euo pipefail

declare -A MARKET_REPOS=(
  [nl]="silverfin/nl_market"
  [be]="silverfin/be_market"
  [lu]="silverfin/lu_market"
  [uk]="silverfin/uk_market"
)

PARTNER_ID="${1:?Usage: $0 <partner_id> <market> [host]}"
MARKET="${2:?Usage: $0 <partner_id> <market> [host]}"
HOST="${3:-https://bso-staging-beta.staging.getsilverfin.com}"

if [[ -n "${MARKET_REPOS[$MARKET]:-}" ]]; then
  REPO="${MARKET_REPOS[$MARKET]}"
else
  REPO="$MARKET"
fi

printf '%s' "API key for partner ${PARTNER_ID} (${REPO}): "
read -rs API_KEY
echo

TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

HOME="$TMP_HOME" silverfin config --set-host "$HOST"
HOME="$TMP_HOME" silverfin authorize-partner -i "$PARTNER_ID" -k "$API_KEY" -n "partner-${PARTNER_ID}"

gh secret set "PARTNER_CONFIG_JSON_${PARTNER_ID}" --repo "$REPO" < "$TMP_HOME/.silverfin/config.json"

echo "Done: PARTNER_CONFIG_JSON_${PARTNER_ID} updated on ${REPO}."
