#!/bin/bash

# =============================================================================
# Keycloak Plugin Configuration
# =============================================================================
# This script deploys and configures Keycloak (via Bitnami Helm chart) and
# provisions the OIDC client, realm, and user/group data needed by the
# Keycloak catalog backend plugin.
#
# Functions are structured for efficient round-robin execution:
#   1. deploy_keycloak                     — Install Helm chart + create Route (quick)
#   2. config_secrets_for_keycloak_plugins — Wait for readiness, then create realm/client/
#                                            roles, write secrets, register plugin overlay
#   3. create_users_and_groups_keycloak    — Provision groups and users via API
#   4. apply_keycloak_labels               — Label resources for the K8s plugin
#
# Readiness polling is embedded at the top of config_secrets_for_keycloak_plugins
# rather than as a standalone step. This keeps the round-robin loop doing useful
# work on other plugins instead of burning a full turn on a pure wait.
#
# Uses plain HTTP for the Keycloak route to avoid self-signed certificate issues
# when RHDH (Node.js) connects to Keycloak's OIDC endpoints.
# =============================================================================

_KEYCLOAK_RELEASE_NAME="keycloak"
_KEYCLOAK_CLIENT_FILE="${PWD}/resources/keycloak/rhdh-client.json"
_KEYCLOAK_USERS_FILE="${PWD}/resources/keycloak/users.json"
_KEYCLOAK_GROUPS_FILE="${PWD}/resources/keycloak/groups.json"
_KEYCLOAK_VALUES_FILE="${PWD}/resources/keycloak/keycloak-values.yaml"

# Shared state set by config_secrets_for_keycloak_plugins and consumed by
# create_users_and_groups_keycloak. Declared here so they are always in scope
# when the file is sourced by config-plugins.sh.
KEYCLOAK_URL=""
ADMIN_TOKEN=""

# =============================================================================
# Helper: Keycloak REST API wrapper
# Prefixed to avoid collisions when sourced alongside other plugin scripts.
# =============================================================================
_keycloak_api_call() {
  local method=$1
  local url=$2
  local data=$3
  local description=$4
  local response http_code body

  if [[ -n "$data" ]]; then
    response=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data")
  else
    response=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json")
  fi

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$method" == "GET" ]] || [[ "$http_code" -lt 400 ]]; then
    echo "$body"
    return 0
  fi

  # 409 Conflict is acceptable for idempotent create operations.
  if [[ "$http_code" == "409" ]]; then
    echo "Warning: ${description} — already exists (continuing)" >&2
    echo "$body"
    return 0
  fi

  echo "Error: ${description} failed (HTTP ${http_code}): ${body}" >&2
  return 1
}


# =============================================================================
# Step 1: Deploy Keycloak (quick action — no waiting)
# =============================================================================
deploy_keycloak() {
  echo "Creating namespace ${NAMESPACE}..."
  oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

  # Generate Keycloak credentials only on first run — skip if the secret already
  # exists so that re-runs against a live Keycloak never rotate passwords that
  # the running instance depends on.
  if oc get secret keycloak-credentials --namespace="${NAMESPACE}" &>/dev/null; then
    echo "keycloak-credentials already exists — skipping generation."
  else
    echo "Generating keycloak-credentials Secret..."
    local kc_admin_password kc_db_password kc_client_secret
    kc_admin_password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    kc_db_password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    kc_client_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

    oc create secret generic keycloak-credentials \
      --from-literal=admin-password="${kc_admin_password}" \
      --from-literal=KEYCLOAK_ADMIN_PASSWORD="${kc_admin_password}" \
      --from-literal=postgres-password="${kc_db_password}" \
      --from-literal=password="${kc_db_password}" \
      --from-literal=client-secret="${kc_client_secret}" \
      --namespace="${NAMESPACE}"
  fi

  echo "Adding Bitnami Helm repository..."
  helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
  helm repo update

  echo "Deploying Keycloak via Helm..."
  helm upgrade --install "${_KEYCLOAK_RELEASE_NAME}" bitnami/keycloak \
    --namespace "${NAMESPACE}" \
    --values <(envsubst < "${_KEYCLOAK_VALUES_FILE}")

  echo "Creating OpenShift Route (HTTP, no TLS)..."
  oc apply -f - --namespace="${NAMESPACE}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${_KEYCLOAK_RELEASE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/instance: ${_KEYCLOAK_RELEASE_NAME}
spec:
  to:
    kind: Service
    name: ${_KEYCLOAK_RELEASE_NAME}
    weight: 100
  port:
    targetPort: http
  wildcardPolicy: None
EOF

  echo "Keycloak deployment applied!"
}

# =============================================================================
# Step 2: Create realm/client/roles and write plugin secrets
#         (waits for Keycloak readiness internally before proceeding)
# =============================================================================
config_secrets_for_keycloak_plugins() {
  echo "Configuring Keycloak realm, client, and plugin secrets..."

  if [[ ! -f "${_KEYCLOAK_CLIENT_FILE}" ]]; then
    echo "Error: Client file not found: ${_KEYCLOAK_CLIENT_FILE}"
    return 1
  fi
  jq empty "${_KEYCLOAK_CLIENT_FILE}" 2>/dev/null || {
    echo "Error: Invalid JSON in ${_KEYCLOAK_CLIENT_FILE}"
    return 1
  }

  # ---- Wait for StatefulSet ----
  echo "Waiting for Keycloak StatefulSet to become ready..."
  SECONDS=0
  while true; do
    local ready
    ready=$(oc get statefulset "${_KEYCLOAK_RELEASE_NAME}" \
      --namespace="${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready}" == "1" ]] && echo "Keycloak StatefulSet is ready!" && break
    if [[ $SECONDS -ge ${TIMEOUT:-300} ]]; then
      echo "Warning: Timeout waiting for Keycloak StatefulSet — continuing anyway."
      break
    fi
    echo "  Keycloak not ready yet (readyReplicas=${ready:-0}). Retrying in ${INTERVAL:-15}s..."
    sleep "${INTERVAL:-15}"
  done

  local keycloak_host
  keycloak_host=$(oc get route "${_KEYCLOAK_RELEASE_NAME}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  if [[ -z "$keycloak_host" ]]; then
    echo "Error: Could not determine Keycloak route URL."
    return 1
  fi

  # Populate the globals consumed by create_users_and_groups_keycloak.
  KEYCLOAK_URL="http://${keycloak_host}"

  # ---- Wait for Keycloak API ----
  local check_url="${KEYCLOAK_URL}/realms/master"
  echo "Waiting for Keycloak API at ${check_url}..."
  SECONDS=0
  while true; do
    local http_status
    http_status=$(curl -sk -o /dev/null -w "%{http_code}" "$check_url" 2>/dev/null || echo "000")
    if [[ "$http_status" == "200" ]]; then
      echo "Keycloak API is ready!"
      break
    fi
    if [[ $SECONDS -ge ${TIMEOUT:-300} ]]; then
      echo "Warning: Timeout waiting for Keycloak API (last status: ${http_status}) — continuing anyway."
      break
    fi
    echo "  Waiting for API... (status: ${http_status})"
    sleep "${INTERVAL:-15}"
  done

  echo "Getting admin token..."
  local kc_admin_password
  kc_admin_password=$(oc get secret keycloak-credentials \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.data.admin-password}' | base64 -d)

  local token_response token_http_code token_body
  token_response=$(curl -sk -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "username=admin&password=${kc_admin_password}&grant_type=password&client_id=admin-cli")
  token_http_code=$(echo "$token_response" | tail -1)
  token_body=$(echo "$token_response" | sed '$d')

  if [[ "$token_http_code" -ge 400 ]]; then
    echo "Error: Failed to get admin token (HTTP ${token_http_code}): ${token_body}"
    return 1
  fi

  ADMIN_TOKEN=$(echo "$token_body" | jq -r '.access_token // empty')
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    echo "Error: Failed to parse admin token."
    return 1
  fi

  echo "Creating realm 'rhdh'..."
  _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms" \
    '{"realm":"rhdh","enabled":true,"displayName":"RHDH Realm"}' \
    "Create realm" >/dev/null

  echo "Creating OIDC client..."
  : "${RHDH_BASE_URL:?RHDH_BASE_URL must be set — cannot build OIDC redirect URI}"
  local rhdh_redirect_uri="${RHDH_BASE_URL}/api/auth/oidc/handler/frame"
  local kc_client_secret
  kc_client_secret=$(oc get secret keycloak-credentials \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.data.client-secret}' | base64 -d)

  _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms/rhdh/clients" \
    "$(jq -c \
        --arg secret "${kc_client_secret}" \
        --arg redirect_uri "${rhdh_redirect_uri}" \
        '.secret = $secret | .redirectUris = [$redirect_uri] | .webOrigins = [$redirect_uri]' \
        "${_KEYCLOAK_CLIENT_FILE}")" \
    "Create client" >/dev/null

  local service_account_id realm_mgmt_id roles

  service_account_id=$(_keycloak_api_call GET \
    "${KEYCLOAK_URL}/admin/realms/rhdh/users?username=service-account-rhdh-client" \
    "" "Get service account" | jq -r '.[0].id // empty')

  if [[ -z "$service_account_id" ]]; then
    echo "Error: Service account not found — was the client created with serviceAccountsEnabled?"
    return 1
  fi

  realm_mgmt_id=$(_keycloak_api_call GET \
    "${KEYCLOAK_URL}/admin/realms/rhdh/clients?clientId=realm-management" \
    "" "Get realm-management client" | jq -r '.[0].id // empty')

  if [[ -z "$realm_mgmt_id" ]]; then
    echo "Error: realm-management client not found."
    return 1
  fi

  roles=$(_keycloak_api_call GET \
    "${KEYCLOAK_URL}/admin/realms/rhdh/clients/${realm_mgmt_id}/roles" \
    "" "Get roles" | \
    jq -c '[.[] | select(.name == "view-authorization" or .name == "manage-authorization" or .name == "view-users")]')

  if [[ -z "$roles" || "$roles" == "[]" ]]; then
    echo "Error: Required service account roles not found."
    return 1
  fi

  echo "Assigning service account roles..."
  _keycloak_api_call POST \
    "${KEYCLOAK_URL}/admin/realms/rhdh/users/${service_account_id}/role-mappings/clients/${realm_mgmt_id}" \
    "$roles" "Assign service account roles" >/dev/null

  # Export for use by deploy.sh and any downstream scripts.
  export KEYCLOAK_CLIENT_SECRET="${kc_client_secret}"
  export KEYCLOAK_CLIENT_ID="rhdh-client"
  export KEYCLOAK_REALM="rhdh"
  export KEYCLOAK_LOGIN_REALM="rhdh"
  export KEYCLOAK_METADATA_URL="${KEYCLOAK_URL}/realms/rhdh"
  export KEYCLOAK_BASE_URL="${KEYCLOAK_URL}"

  oc patch secret rhdh-secrets -n "${NAMESPACE}" \
    --type=merge -p "{\"stringData\":{
      \"KEYCLOAK_BASE_URL\":\"${KEYCLOAK_URL}\",
      \"KEYCLOAK_METADATA_URL\":\"${KEYCLOAK_URL}/realms/rhdh\",
      \"KEYCLOAK_CLIENT_ID\":\"rhdh-client\",
      \"KEYCLOAK_CLIENT_SECRET\":\"${kc_client_secret}\",
      \"KEYCLOAK_REALM\":\"rhdh\",
      \"KEYCLOAK_LOGIN_REALM\":\"rhdh\"}}"

  export IS_AUTH_ENABLED=true

  _append_plugin_dynamic_config "${PWD}/resources/keycloak/dynamic-plugins.yaml" "Keycloak"

  echo "Keycloak plugin secrets and overlay configured!"
}

# =============================================================================
# Step 4: Create groups and users in the rhdh realm
# =============================================================================
create_users_and_groups_keycloak() {
  echo "Creating Keycloak groups and users..."

  # Generate a single random password for all test users at runtime.
  # Alphanumeric-only avoids shell-quoting and JSON-escaping issues.
  export USER_PASSWORD
  USER_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

  # Re-fetch the admin token here — the token obtained in
  # config_secrets_for_keycloak_plugins may have expired by the time this
  # function runs (default Keycloak token lifetime is 60s, and with hundreds
  # of users the loop takes longer than that).
  local kc_admin_password
  kc_admin_password=$(oc get secret keycloak-credentials \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.data.admin-password}' | base64 -d)

  local token_response
  token_response=$(curl -sk -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "username=admin&password=${kc_admin_password}&grant_type=password&client_id=admin-cli")

  local token_http_code token_body
  token_http_code=$(echo "$token_response" | tail -1)
  token_body=$(echo "$token_response" | sed '$d')

  if [[ "$token_http_code" -ge 400 ]]; then
    echo "Error: Failed to refresh admin token (HTTP ${token_http_code}): ${token_body}"
    return 1
  fi

  ADMIN_TOKEN=$(echo "$token_body" | jq -r '.access_token // empty')
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    echo "Error: Failed to parse refreshed admin token."
    return 1
  fi
  echo "Admin token refreshed."

  if [[ -f "${_KEYCLOAK_GROUPS_FILE}" ]]; then
    jq empty "${_KEYCLOAK_GROUPS_FILE}" 2>/dev/null || {
      echo "Warning: Invalid JSON in ${_KEYCLOAK_GROUPS_FILE} — skipping groups."
    }
    echo "Creating groups..."
    jq -r '.[].name' "${_KEYCLOAK_GROUPS_FILE}" | while read -r group; do
      _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms/rhdh/groups" \
        "{\"name\":\"${group}\"}" \
        "Create group '${group}'" >/dev/null \
        && echo "  Created group: ${group}" \
        || echo "  Warning: Failed to create group: ${group}"
    done
  fi

  if [[ -f "${_KEYCLOAK_USERS_FILE}" ]]; then
    jq empty "${_KEYCLOAK_USERS_FILE}" 2>/dev/null || {
      echo "Warning: Invalid JSON in ${_KEYCLOAK_USERS_FILE} — skipping users."
      return 0
    }
    echo "Creating users..."
    jq -c '.[]' "${_KEYCLOAK_USERS_FILE}" | while read -r user_json; do
      local username user_payload groups user_id
      username=$(echo "$user_json" | jq -r '.username')
      groups=$(echo "$user_json" | jq -r '.groups // [] | join(",")')
      # Inject the runtime-generated password; credentials are not stored in users.json.
      user_payload=$(echo "$user_json" | jq -c --arg pw "${USER_PASSWORD}" \
        'del(.groups) | .credentials = [{"type":"password","value":$pw,"temporary":false}]')

      if ! _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms/rhdh/users" \
          "$user_payload" "Create user '${username}'" >/dev/null; then
        echo "  Warning: Failed to create user: ${username}"
        continue
      fi
      echo "  Created user: ${username}"

      if [[ -n "$groups" ]]; then
        user_id=$(_keycloak_api_call GET \
          "${KEYCLOAK_URL}/admin/realms/rhdh/users?username=${username}" \
          "" "Get user ID" | jq -r '.[0].id // empty')

        [[ -z "$user_id" ]] && echo "    Warning: Could not find user ID for ${username}" && continue

        for group in $(echo "$groups" | tr ',' ' '); do
          local group_id
          group_id=$(_keycloak_api_call GET \
            "${KEYCLOAK_URL}/admin/realms/rhdh/groups?search=${group}" \
            "" "Get group ID" | jq -r '.[0].id // empty')

          [[ -z "$group_id" ]] && echo "    Warning: Group '${group}' not found" && continue

          _keycloak_api_call PUT \
            "${KEYCLOAK_URL}/admin/realms/rhdh/users/${user_id}/groups/${group_id}" \
            "" "Add ${username} to group ${group}" >/dev/null \
            && echo "    Added to group: ${group}" \
            || echo "    Warning: Failed to add ${username} to group: ${group}"
        done
      fi
    done
  fi

  echo "Users and groups created!"

  # Store test credentials in a cluster Secret so they can be retrieved after
  # deployment via: oc get secret keycloak-test-credentials -n <namespace>
  # All users share the same runtime-generated password; usernames come directly
  # from users.json so there is nothing hardcoded here.
  local usernames
  usernames=$(jq -r '.[].username' "${_KEYCLOAK_USERS_FILE}" | paste -sd ',' -)

  oc create secret generic keycloak-test-credentials \
    --from-literal=KEYCLOAK_URL="${KEYCLOAK_BASE_URL}" \
    --from-literal=KEYCLOAK_USERNAMES="${usernames}" \
    --from-literal=KEYCLOAK_USER_PASSWORD="${USER_PASSWORD}" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -

  echo ""
  echo "  Keycloak test users:  ${usernames}"
  echo "  Shared password:      (stored in secret keycloak-test-credentials)"
  echo "  Admin credentials:    see secret keycloak-credentials (key: admin-password) in namespace ${NAMESPACE}"
  echo ""
}

# =============================================================================
# Step 5: Apply backstage.io/kubernetes-id labels
# =============================================================================
apply_keycloak_labels() {
  echo "Applying Kubernetes labels for Keycloak resources..."

  declare -A patterns=(
    ["keycloak"]="backstage.io/kubernetes-id=keycloak"
  )

  local resource_types=("pods" "deployments" "replicasets" "services" "routes" "statefulsets")

  for resource in "${resource_types[@]}"; do
    for pattern in "${!patterns[@]}"; do
      local label="${patterns[$pattern]}"
      oc get "$resource" -n "${NAMESPACE}" --no-headers \
        -o custom-columns=":metadata.name" 2>/dev/null \
        | grep "$pattern" \
        | xargs -I {} oc label "$resource" {} "$label" --overwrite \
            -n "${NAMESPACE}" 2>/dev/null || true
    done
  done

  echo "Keycloak labels applied!"
}

# =============================================================================
# Teardown
# =============================================================================
uninstall_keycloak() {
  echo "Uninstalling Keycloak..."

  helm uninstall "${_KEYCLOAK_RELEASE_NAME}" --namespace "${NAMESPACE}" 2>/dev/null || true
  oc delete route "${_KEYCLOAK_RELEASE_NAME}" --namespace "${NAMESPACE}" 2>/dev/null || true
  oc delete secret keycloak-credentials --namespace "${NAMESPACE}" 2>/dev/null || true
  oc delete secret keycloak-test-credentials --namespace "${NAMESPACE}" 2>/dev/null || true
  # StatefulSet PVCs are not deleted by Helm uninstall — remove explicitly so
  # a subsequent deploy does not conflict with the leftover volume.
  oc delete pvc "data-${_KEYCLOAK_RELEASE_NAME}-postgresql-0" \
    --namespace "${NAMESPACE}" 2>/dev/null || true

  echo "Keycloak uninstalled!"
}

# =============================================================================
# Main (standalone execution)
# =============================================================================
main() {
  if [[ ! -f "${PWD}/.env" ]]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
  fi
  source "${PWD}/.env"

  echo "=============================================="
  echo "Configuring Keycloak Plugin"
  echo "=============================================="

  deploy_keycloak
  config_secrets_for_keycloak_plugins
  create_users_and_groups_keycloak
  apply_keycloak_labels

  echo ""
  echo "=============================================="
  echo "URL:        ${KEYCLOAK_URL}"
  echo "Admin:      admin"
  echo "Realm:      rhdh"
  echo "User pass:  (stored in secret keycloak-test-credentials)"
  echo "Keycloak configuration complete!"
  echo "=============================================="

  exit "${OVERALL_RESULT:-0}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
