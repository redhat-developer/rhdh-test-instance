#!/bin/bash
# Pin rhdh-client redirectUris and webOrigins to the live RHDH URL.
# Usage: update-rhdh-client-redirects.sh <keycloak-namespace> <rhdh-base-url>
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "Error: oc is required" >&2; exit 1; }

KEYCLOAK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${KEYCLOAK_DIR}/lib.sh"

NAMESPACE="${1:-}"
RHDH_URL="${2:-}"
[[ -n "$NAMESPACE" && -n "$RHDH_URL" ]] || {
    echo "Usage: $0 <keycloak-namespace> <rhdh-base-url>" >&2
    exit 1
}

KEYCLOAK_URL="$(keycloak_route_url "$NAMESPACE")" || {
    echo "Error: Keycloak route not found in $NAMESPACE" >&2
    exit 1
}
redirect="${RHDH_URL%/}/api/auth/oidc/handler/frame"

ADMIN_TOKEN="$(keycloak_admin_token "$KEYCLOAK_URL")"

client_uuid=$(keycloak_api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients?clientId=rhdh-client" "" "Get rhdh-client" | \
    jq -r '.[0].id // empty')
[[ -n "$client_uuid" ]] || { echo "Error: rhdh-client UUID not found" >&2; exit 1; }

payload=$(keycloak_api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$client_uuid" "" "Get rhdh-client representation" | \
    jq -c --arg uri "$redirect" --arg origin "${RHDH_URL%/}" \
      '.redirectUris = [$uri] | .webOrigins = [$origin] | .implicitFlowEnabled = false')
keycloak_api_call PUT "$KEYCLOAK_URL/admin/realms/rhdh/clients/$client_uuid" "$payload" "Pin rhdh-client redirects" >/dev/null
echo "Pinned rhdh-client redirectUris to ${redirect} webOrigins to ${RHDH_URL%/}"
