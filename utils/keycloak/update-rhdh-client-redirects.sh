#!/bin/bash
# Pin rhdh-client redirectUris and webOrigins to the live RHDH URL.
# Usage: update-rhdh-client-redirects.sh <keycloak-namespace> <rhdh-base-url>
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "Error: oc is required" >&2; exit 1; }

NAMESPACE="${1:-}"
RHDH_URL="${2:-}"
[[ -n "$NAMESPACE" && -n "$RHDH_URL" ]] || {
    echo "Usage: $0 <keycloak-namespace> <rhdh-base-url>" >&2
    exit 1
}

if oc get route console -n openshift-console -o=jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
    KEYCLOAK_PROTOCOL="https"
else
    KEYCLOAK_PROTOCOL="http"
fi
host="$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$host" ]] || { echo "Error: Keycloak route not found in $NAMESPACE" >&2; exit 1; }
KEYCLOAK_URL="${KEYCLOAK_PROTOCOL}://${host}"
redirect="${RHDH_URL%/}/api/auth/oidc/handler/frame"

api_call() {
    local method=$1 url=$2 data=$3 description=$4
    local RESPONSE HTTP_CODE BODY
    if [ -n "$data" ]; then
        RESPONSE=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data")
    else
        RESPONSE=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json")
    fi
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    if [ "$method" = "GET" ] || [ "$HTTP_CODE" -lt 400 ]; then
        echo "$BODY"
        return 0
    fi
    if [ "$HTTP_CODE" = "409" ]; then
        echo "$BODY"
        return 0
    fi
    echo "Error: $description failed (HTTP $HTTP_CODE): $BODY" >&2
    return 1
}

token_response=$(curl -sk -w "\n%{http_code}" -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -d "username=admin&password=admin123&grant_type=password&client_id=admin-cli")
TOKEN_HTTP_CODE=$(echo "$token_response" | tail -1)
TOKEN_BODY=$(echo "$token_response" | sed '$d')
[ "$TOKEN_HTTP_CODE" -ge 400 ] && echo "Error: Failed to refresh admin token (HTTP $TOKEN_HTTP_CODE): $TOKEN_BODY" >&2 && exit 1
ADMIN_TOKEN=$(echo "$TOKEN_BODY" | jq -r '.access_token // empty')
[ -z "$ADMIN_TOKEN" ] && echo "Error: Failed to parse refreshed admin token" >&2 && exit 1

client_uuid=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients?clientId=rhdh-client" "" "Get rhdh-client" | \
    jq -r '.[0].id // empty')
[ -z "$client_uuid" ] && echo "Error: rhdh-client UUID not found" >&2 && exit 1

payload=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$client_uuid" "" "Get rhdh-client representation" | \
    jq -c --arg uri "$redirect" --arg origin "${RHDH_URL%/}" \
      '.redirectUris = [$uri] | .webOrigins = [$origin] | .implicitFlowEnabled = false')
api_call PUT "$KEYCLOAK_URL/admin/realms/rhdh/clients/$client_uuid" "$payload" "Pin rhdh-client redirects" >/dev/null
echo "Pinned rhdh-client redirectUris to ${redirect} webOrigins to ${RHDH_URL%/}"
