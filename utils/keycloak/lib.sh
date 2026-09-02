#!/bin/bash
# Shared Keycloak REST helpers for orchestrator smoke setup.
# Source from keycloak-deploy.sh, update-rhdh-client-redirects.sh, and setup-orchestrator.sh.

_KEYCLOAK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_KEYCLOAK_LIB_DIR}/../shell/openshift.sh"

keycloak_console_protocol() {
    if oc get route console -n openshift-console -o=jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
        echo https
    else
        echo http
    fi
}

keycloak_route_url() {
    local namespace="$1"
    local release_name="${2:-keycloak}"
    openshift_route_url "$release_name" "$namespace" http
}

keycloak_admin_token() {
    local keycloak_url="$1"
    local admin_password="${2:-admin123}"
    local token_response token_http_code token_body admin_token
    token_response=$(curl -sk -w "\n%{http_code}" -X POST "$keycloak_url/realms/master/protocol/openid-connect/token" \
        -d "username=admin&password=${admin_password}&grant_type=password&client_id=admin-cli")
    token_http_code=$(echo "$token_response" | tail -1)
    token_body=$(echo "$token_response" | sed '$d')
    if [[ "$token_http_code" -ge 400 ]]; then
        echo "Error: Failed to get admin token (HTTP $token_http_code): $token_body" >&2
        return 1
    fi
    admin_token=$(echo "$token_body" | jq -r '.access_token // empty')
    if [[ -z "$admin_token" ]]; then
        echo "Error: Failed to parse admin token" >&2
        return 1
    fi
    echo "$admin_token"
}

keycloak_api_call() {
    local method=$1
    local url=$2
    local data=$3
    local description=$4
    local response http_code body

    if [[ -n "$data" ]]; then
        response=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data")
    else
        response=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json")
    fi

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$method" == "GET" ]] || [[ "$http_code" -lt 400 ]]; then
        echo "$body"
        return 0
    fi

    if [[ "$http_code" == "409" ]]; then
        echo "Warning: $description - already exists (continuing)" >&2
        echo "$body"
        return 0
    fi

    echo "Error: $description failed (HTTP $http_code): $body" >&2
    return 1
}

export_keycloak_runtime_env() {
    local ns="$1"
    local url
    url="$(keycloak_route_url "$ns")" || {
        echo "Error: could not resolve Keycloak route in namespace '$ns'." >&2
        return 1
    }
    export KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-$url}"
    export KEYCLOAK_METADATA_URL="${KEYCLOAK_BASE_URL}/realms/rhdh"
    export KEYCLOAK_REALM="${KEYCLOAK_REALM:-rhdh}"
    export KEYCLOAK_LOGIN_REALM="${KEYCLOAK_LOGIN_REALM:-${KEYCLOAK_REALM}}"
    export KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-rhdh-client}"
    export KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-rhdh-client-secret}"
    if [[ -z "${KEYCLOAK_LOGIN_REALM}" ]]; then
        echo "Error: KEYCLOAK_LOGIN_REALM resolved to empty value." >&2
        return 1
    fi
}
