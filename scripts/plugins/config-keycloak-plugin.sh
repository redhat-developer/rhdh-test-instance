#!/usr/bin/env bash

# =============================================================================
# config-keycloak-plugin.sh — Shared Keycloak with per-instance OIDC clients
#
# Keycloak is deployed once into a dedicated namespace (KEYCLOAK_NS, default:
# rhdh-keycloak) and shared by every RHDH instance on the cluster. The realm,
# users and groups are shared too; each RHDH namespace gets its own OIDC client
# so redirect URIs never collide.
#
# The public route uses plain HTTP on purpose: cluster-pool ingress
# certificates are self-signed, and RHDH would otherwise need to trust them.
#
# Steps:
#   1. deploy_keycloak                      Helm chart + HTTP route (idempotent)
#   2. create_users_and_groups_keycloak     realm, groups, users (idempotent)
#   3. register_keycloak_client             per-namespace OIDC client
#   4. config_secrets_for_keycloak_plugins  KEYCLOAK_* into rhdh-secrets
#   5. apply_keycloak_labels                labels for the Kubernetes plugin
# =============================================================================

KEYCLOAK_NS="${KEYCLOAK_NS:-rhdh-keycloak}"

_KEYCLOAK_RELEASE_NAME="keycloak"
_KEYCLOAK_CLIENT_FILE="${DEPLOY_ROOT}/resources/keycloak/rhdh-client.json"
_KEYCLOAK_USERS_FILE="${DEPLOY_ROOT}/resources/keycloak/users.json"
_KEYCLOAK_GROUPS_FILE="${DEPLOY_ROOT}/resources/keycloak/groups.json"
_KEYCLOAK_VALUES_FILE="${DEPLOY_ROOT}/resources/keycloak/keycloak-values.yaml"

KEYCLOAK_URL=""
ADMIN_TOKEN=""

# =============================================================================
# Keycloak REST API wrapper
# =============================================================================
_keycloak_api_call() {
  local method=$1
  local url=$2
  local data=${3:-}
  local description=$4

  local response http_code body
  if [[ -n "$data" ]]; then
    response=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data")
  else
    response=$(curl -sk -w "\n%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}")
  fi

  http_code=$(echo "$response" | tail -n 1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
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
# Helper: wait for Keycloak and populate KEYCLOAK_URL + ADMIN_TOKEN
# =============================================================================
_keycloak_ensure_ready() {
  if [[ -n "${KEYCLOAK_URL}" && -n "${ADMIN_TOKEN}" ]]; then
    return 0
  fi

  echo "Waiting for Keycloak StatefulSet in ${KEYCLOAK_NS}..."
  local seconds=0
  while true; do
    local ready
    ready=$(oc get statefulset "${_KEYCLOAK_RELEASE_NAME}" \
      --namespace="${KEYCLOAK_NS}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready}" == "1" ]] && echo "Keycloak StatefulSet is ready!" && break
    if [[ $seconds -ge ${TIMEOUT:-600} ]]; then
      echo "Error: Timeout waiting for Keycloak StatefulSet."
      return 1
    fi
    echo "  Keycloak not ready yet (readyReplicas=${ready:-0}). Retrying in ${INTERVAL:-15}s..."
    sleep "${INTERVAL:-15}"
    seconds=$((seconds + ${INTERVAL:-15}))
  done

  local keycloak_host
  keycloak_host=$(oc get route "${_KEYCLOAK_RELEASE_NAME}" \
    --namespace="${KEYCLOAK_NS}" \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  if [[ -z "$keycloak_host" ]]; then
    echo "Error: Could not determine Keycloak route URL in ${KEYCLOAK_NS}."
    return 1
  fi

  KEYCLOAK_URL="http://${keycloak_host}"

  local check_url="${KEYCLOAK_URL}/realms/master"
  echo "Waiting for Keycloak API at ${check_url}..."
  seconds=0
  while true; do
    local http_status
    http_status=$(curl -sk -o /dev/null -w "%{http_code}" "$check_url" 2>/dev/null || echo "000")
    [[ "$http_status" == "200" ]] && break
    if [[ $seconds -ge ${TIMEOUT:-300} ]]; then
      echo "Error: Timeout waiting for Keycloak API."
      return 1
    fi
    sleep "${INTERVAL:-15}"
    seconds=$((seconds + ${INTERVAL:-15}))
  done

  _keycloak_refresh_admin_token
}

_keycloak_refresh_admin_token() {
  local kc_admin_password
  kc_admin_password=$(oc get secret keycloak-credentials \
    --namespace="${KEYCLOAK_NS}" \
    -o jsonpath='{.data.admin-password}' | base64 -d)

  local token_response token_http_code token_body
  token_response=$(curl -sk -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" \
    -d "password=${kc_admin_password}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli")

  token_http_code=$(echo "$token_response" | tail -n 1)
  token_body=$(echo "$token_response" | sed '$d')

  if [[ ! "$token_http_code" =~ ^2[0-9]{2}$ ]]; then
    echo "Error: Failed to get admin token (HTTP ${token_http_code}): ${token_body}"
    return 1
  fi

  ADMIN_TOKEN=$(echo "$token_body" | jq -r '.access_token')
  if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
    echo "Error: Failed to parse admin token."
    return 1
  fi
  echo "Admin token acquired."
}

# =============================================================================
# Step 1: Deploy Keycloak infra into KEYCLOAK_NS (skip if already present)
# =============================================================================
deploy_keycloak() {
  oc create namespace "${KEYCLOAK_NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

  # On a shared cluster every instance deploy runs this step. Re-running the
  # Helm release concurrently fails with "another operation in progress", so
  # an already running Keycloak is reused as-is.
  local keycloak_ready=false
  if [[ "$(oc get statefulset "${_KEYCLOAK_RELEASE_NAME}" \
      --namespace="${KEYCLOAK_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" == "1" ]]; then
    keycloak_ready=true
    echo "Keycloak is already running in ${KEYCLOAK_NS} — skipping install."
  fi

  if [[ "${keycloak_ready}" == "false" ]]; then
    if oc get secret keycloak-credentials --namespace="${KEYCLOAK_NS}" &>/dev/null; then
      echo "keycloak-credentials already exists in ${KEYCLOAK_NS} — skipping generation."
    else
      echo "Generating keycloak-credentials Secret in ${KEYCLOAK_NS}..."
      local kc_admin_password kc_db_password
      kc_admin_password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
      kc_db_password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

      oc create secret generic keycloak-credentials \
        --from-literal=admin-password="${kc_admin_password}" \
        --from-literal=KEYCLOAK_ADMIN_PASSWORD="${kc_admin_password}" \
        --from-literal=postgres-password="${kc_db_password}" \
        --from-literal=password="${kc_db_password}" \
        --namespace="${KEYCLOAK_NS}"
    fi

    echo "Importing Keycloak images into ${KEYCLOAK_NS}..."
    local import_dir="${DEPLOY_ROOT}/resources/image-stream-imports"
    for f in keycloak-legacy-import.yaml postgesql-legacy-import.yaml; do
      if [[ -f "${import_dir}/${f}" ]]; then
        oc apply -f "${import_dir}/${f}" --namespace="${KEYCLOAK_NS}" >/dev/null || \
          echo "  Warning: Failed to import ${f} — continuing."
      fi
    done

    helm repo add bitnami https://charts.bitnami.com/bitnami --force-update >/dev/null
    helm repo update >/dev/null

    echo "Deploying Keycloak via Helm into ${KEYCLOAK_NS}..."
    # keycloak-values.yaml uses ${NAMESPACE} for internal registry paths — override
    # it so envsubst substitutes the Keycloak namespace, not the RHDH instance NS.
    helm upgrade --install "${_KEYCLOAK_RELEASE_NAME}" bitnami/keycloak \
      --namespace "${KEYCLOAK_NS}" \
      --values <(NAMESPACE="${KEYCLOAK_NS}" envsubst < "${_KEYCLOAK_VALUES_FILE}")
  fi

  # The route is applied every time so a deleted or stale route is repaired
  # without touching the running release.
  echo "Creating OpenShift Route (HTTP) in ${KEYCLOAK_NS}..."
  oc apply -f - --namespace="${KEYCLOAK_NS}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${_KEYCLOAK_RELEASE_NAME}
  namespace: ${KEYCLOAK_NS}
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

  echo "Keycloak deployment applied in ${KEYCLOAK_NS}!"
}

# =============================================================================
# Step 2: Create realm, groups, and users in the shared Keycloak
# =============================================================================
create_users_and_groups_keycloak() {
  _keycloak_ensure_ready

  echo "Creating realm 'rhdh'..."
  _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms" \
    '{"realm":"rhdh","enabled":true,"displayName":"RHDH Realm"}' \
    "Create realm" >/dev/null

  echo "Creating Keycloak groups and users..."

  local user_password_fallback="changeme"

  # Refresh token before the potentially long user-creation loop.
  _keycloak_refresh_admin_token

  if [[ -f "${_KEYCLOAK_GROUPS_FILE}" ]]; then
    jq empty "${_KEYCLOAK_GROUPS_FILE}" 2>/dev/null || {
      echo "Warning: Invalid JSON in ${_KEYCLOAK_GROUPS_FILE} — skipping groups."
    }
    echo "Creating groups..."
    local group
    while read -r group; do
      _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms/rhdh/groups" \
        "{\"name\":\"${group}\"}" \
        "Create group '${group}'" >/dev/null \
        && echo "  Created (or kept) group: ${group}" \
        || echo "  Warning: Failed to create group: ${group}"
    done < <(jq -r '.[].name' "${_KEYCLOAK_GROUPS_FILE}")
  fi

  if [[ -f "${_KEYCLOAK_USERS_FILE}" ]]; then
    jq empty "${_KEYCLOAK_USERS_FILE}" 2>/dev/null || {
      echo "Warning: Invalid JSON in ${_KEYCLOAK_USERS_FILE} — skipping users."
      return 0
    }
    echo "Creating users..."
    local _user_count=0 user_json username user_payload groups user_id
    while read -r user_json; do
      # Refresh token every 10 users to avoid 60s token expiry.
      if (( _user_count > 0 && _user_count % 10 == 0 )); then
        _keycloak_refresh_admin_token
      fi
      (( _user_count++ )) || true
      username=$(echo "$user_json" | jq -r '.username')
      groups=$(echo "$user_json" | jq -r '.groups // [] | join(",")')
      user_payload=$(echo "$user_json" | jq -c --arg pw "${user_password_fallback}" \
        'del(.groups) | if .credentials then . else .credentials = [{"type":"password","value":$pw,"temporary":false}] end')

      if ! _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms/rhdh/users" \
          "$user_payload" "Create user '${username}'" >/dev/null; then
        echo "  Warning: Failed to create user: ${username}"
        continue
      fi
      echo "  Created (or kept) user: ${username}"

      if [[ -n "$groups" ]]; then
        user_id=$(_keycloak_api_call GET \
          "${KEYCLOAK_URL}/admin/realms/rhdh/users?username=${username}" \
          "" "Get user ID" | jq -r '.[0].id // empty')

        if [[ -z "$user_id" ]]; then
          echo "    Warning: Could not find user ID for ${username}"
          continue
        fi

        local group_name group_id
        for group_name in $(echo "$groups" | tr ',' ' '); do
          group_id=$(_keycloak_api_call GET \
            "${KEYCLOAK_URL}/admin/realms/rhdh/groups?search=${group_name}" \
            "" "Get group ID" | jq -r '.[0].id // empty')

          if [[ -z "$group_id" ]]; then
            echo "    Warning: Group '${group_name}' not found"
            continue
          fi

          _keycloak_api_call PUT \
            "${KEYCLOAK_URL}/admin/realms/rhdh/users/${user_id}/groups/${group_id}" \
            "" "Add ${username} to group ${group_name}" >/dev/null \
            && echo "    Added to group: ${group_name}" \
            || echo "    Warning: Failed to add ${username} to group: ${group_name}"
        done
      fi
    done < <(jq -c '.[]' "${_KEYCLOAK_USERS_FILE}")
  fi

  echo "Users and groups created!"

  local usernames
  usernames=$(jq -r '.[].username' "${_KEYCLOAK_USERS_FILE}" | paste -sd ',' -)

  oc create secret generic keycloak-test-credentials \
    --from-literal=KEYCLOAK_URL="${KEYCLOAK_URL}" \
    --from-literal=KEYCLOAK_USERNAMES="${usernames}" \
    --namespace="${KEYCLOAK_NS}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  echo ""
  echo "  Keycloak test users:  ${usernames}"
  echo "  Passwords:            <username>@123  (e.g. test1@123, test2@123)"
  echo "  Admin credentials:    see secret keycloak-credentials in ${KEYCLOAK_NS}"
  echo ""
}

# =============================================================================
# Step 3: Register a per-instance OIDC client for this RHDH namespace
# =============================================================================
register_keycloak_client() {
  _keycloak_ensure_ready
  _keycloak_refresh_admin_token

  if [[ ! -f "${_KEYCLOAK_CLIENT_FILE}" ]]; then
    echo "Error: Client file not found: ${_KEYCLOAK_CLIENT_FILE}"
    return 1
  fi
  jq empty "${_KEYCLOAK_CLIENT_FILE}" 2>/dev/null || {
    echo "Error: Invalid JSON in ${_KEYCLOAK_CLIENT_FILE}"
    return 1
  }

  local client_id="rhdh-client-${NAMESPACE}"
  : "${RHDH_BASE_URL:?RHDH_BASE_URL must be set — cannot build OIDC redirect URI}"
  local rhdh_redirect_uri="${RHDH_BASE_URL}/api/auth/oidc/handler/frame"

  local kc_client_secret
  kc_client_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

  echo "Creating OIDC client '${client_id}' for ${RHDH_BASE_URL}..."
  _keycloak_api_call POST "${KEYCLOAK_URL}/admin/realms/rhdh/clients" \
    "$(jq -c \
        --arg cid "${client_id}" \
        --arg secret "${kc_client_secret}" \
        --arg redirect_uri "${rhdh_redirect_uri}" \
        '.clientId = $cid | .name = ("RHDH Client — " + $cid) | .secret = $secret | .redirectUris = [$redirect_uri] | .webOrigins = [$redirect_uri]' \
        "${_KEYCLOAK_CLIENT_FILE}")" \
    "Create client '${client_id}'" >/dev/null

  # If the client already existed (409), fetch its existing secret instead of
  # using the newly generated one, so we don't desync with what Keycloak has.
  local existing_client_uuid
  existing_client_uuid=$(_keycloak_api_call GET \
    "${KEYCLOAK_URL}/admin/realms/rhdh/clients?clientId=${client_id}" \
    "" "Get client UUID" | jq -r '.[0].id // empty')

  if [[ -n "$existing_client_uuid" ]]; then
    local existing_secret
    existing_secret=$(_keycloak_api_call GET \
      "${KEYCLOAK_URL}/admin/realms/rhdh/clients/${existing_client_uuid}/client-secret" \
      "" "Get client secret" | jq -r '.value // empty')
    if [[ -n "$existing_secret" ]]; then
      kc_client_secret="${existing_secret}"
    fi

    # Redirect URIs must follow the current instance URL (cluster pool rotation).
    # Send only the fields we own: the template also carries clientId/name/secret,
    # and updating those would rename the client (or reset its secret).
    _keycloak_api_call PUT \
      "${KEYCLOAK_URL}/admin/realms/rhdh/clients/${existing_client_uuid}" \
      "$(jq -c -n --arg redirect_uri "${rhdh_redirect_uri}" \
          '{redirectUris: [$redirect_uri], webOrigins: [$redirect_uri]}')" \
      "Update client redirect URIs" >/dev/null
  fi

  # Assign service account roles for the catalog backend plugin.
  local service_account_id realm_mgmt_id roles

  service_account_id=$(_keycloak_api_call GET \
    "${KEYCLOAK_URL}/admin/realms/rhdh/users?username=service-account-${client_id}" \
    "" "Get service account" | jq -r '.[0].id // empty')

  if [[ -z "$service_account_id" ]]; then
    echo "Warning: Service account for ${client_id} not found — role assignment skipped."
  else
    realm_mgmt_id=$(_keycloak_api_call GET \
      "${KEYCLOAK_URL}/admin/realms/rhdh/clients?clientId=realm-management" \
      "" "Get realm-management client" | jq -r '.[0].id // empty')

    if [[ -n "$realm_mgmt_id" ]]; then
      roles=$(_keycloak_api_call GET \
        "${KEYCLOAK_URL}/admin/realms/rhdh/clients/${realm_mgmt_id}/roles" \
        "" "Get roles" | \
        jq -c '[.[] | select(.name == "view-authorization" or .name == "manage-authorization" or .name == "view-users")]')

      if [[ -n "$roles" && "$roles" != "[]" ]]; then
        echo "Assigning service account roles..."
        _keycloak_api_call POST \
          "${KEYCLOAK_URL}/admin/realms/rhdh/users/${service_account_id}/role-mappings/clients/${realm_mgmt_id}" \
          "$roles" "Assign service account roles" >/dev/null
      fi
    fi
  fi

  export _KC_INSTANCE_CLIENT_ID="${client_id}"
  export _KC_INSTANCE_CLIENT_SECRET="${kc_client_secret}"

  echo "OIDC client '${client_id}' registered!"
}

# =============================================================================
# Step 4: Write Keycloak secrets into rhdh-secrets in the RHDH namespace
# =============================================================================
config_secrets_for_keycloak_plugins() {
  if [[ -z "${KEYCLOAK_URL}" ]]; then
    _keycloak_ensure_ready
  fi

  local client_id="${_KC_INSTANCE_CLIENT_ID:-rhdh-client-${NAMESPACE}}"
  local client_secret="${_KC_INSTANCE_CLIENT_SECRET:-}"
  local client_uuid

  # If the client secret wasn't set by register_keycloak_client (e.g. script
  # was re-run), fetch it from Keycloak.
  if [[ -z "${client_secret}" ]]; then
    client_uuid=$(_keycloak_api_call GET \
      "${KEYCLOAK_URL}/admin/realms/rhdh/clients?clientId=${client_id}" \
      "" "Get client UUID" | jq -r '.[0].id // empty')
    if [[ -n "$client_uuid" ]]; then
      client_secret=$(_keycloak_api_call GET \
        "${KEYCLOAK_URL}/admin/realms/rhdh/clients/${client_uuid}/client-secret" \
        "" "Get client secret" | jq -r '.value // empty')
    fi
  fi

  if [[ -z "${client_secret}" ]]; then
    echo "Error: Could not determine client secret for ${client_id}."
    return 1
  fi

  echo "Patching rhdh-secrets in ${NAMESPACE} with Keycloak config..."

  export KEYCLOAK_CLIENT_SECRET="${client_secret}"
  export KEYCLOAK_CLIENT_ID="${client_id}"
  export KEYCLOAK_REALM="rhdh"
  export KEYCLOAK_LOGIN_REALM="rhdh"
  export KEYCLOAK_METADATA_URL="${KEYCLOAK_URL}/realms/rhdh"
  export KEYCLOAK_BASE_URL="${KEYCLOAK_URL}"

  oc patch secret rhdh-secrets -n "${NAMESPACE}" \
    --type=merge -p "{\"stringData\":{
      \"KEYCLOAK_BASE_URL\":\"${KEYCLOAK_URL}\",
      \"KEYCLOAK_METADATA_URL\":\"${KEYCLOAK_URL}/realms/rhdh\",
      \"KEYCLOAK_CLIENT_ID\":\"${client_id}\",
      \"KEYCLOAK_CLIENT_SECRET\":\"${client_secret}\",
      \"KEYCLOAK_REALM\":\"rhdh\",
      \"KEYCLOAK_LOGIN_REALM\":\"rhdh\"}}"

  echo "Keycloak secrets configured for ${NAMESPACE}!"
}

# =============================================================================
# Step 5: Allow HTTP egress to the Keycloak route
#
# RHDH 2.2 installs a default-deny NetworkPolicy plus an allow-https-egress
# policy (443/6443). The shared Keycloak uses a plain HTTP route, so the OIDC
# metadata discovery and token exchange time out without an explicit port 80
# egress rule.
# =============================================================================
apply_keycloak_egress_policy() {
  echo "Allowing HTTP egress to the Keycloak route in ${NAMESPACE}..."
  oc apply -f - --namespace="${NAMESPACE}" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rhdh-keycloak-egress
spec:
  podSelector:
    matchLabels:
      backstage.io/kubernetes-id: developer-hub
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 80
EOF
  echo "Keycloak egress policy applied!"
}

# =============================================================================
# Step 6: Apply backstage.io/kubernetes-id labels on Keycloak resources
# =============================================================================
apply_keycloak_labels() {
  echo "Applying Kubernetes labels for Keycloak resources in ${KEYCLOAK_NS}..."

  local resource_types=("pods" "deployments" "replicasets" "services" "routes" "statefulsets")
  local resource

  for resource in "${resource_types[@]}"; do
    oc get "$resource" -n "${KEYCLOAK_NS}" --no-headers \
      -o custom-columns=":metadata.name" 2>/dev/null \
      | grep keycloak \
      | xargs -I {} oc label "$resource" {} "backstage.io/kubernetes-id=keycloak" --overwrite \
          -n "${KEYCLOAK_NS}" 2>/dev/null || true
  done

  echo "Keycloak labels applied!"
}

# =============================================================================
# Teardown: per-instance (remove OIDC client only, keep shared Keycloak)
# =============================================================================
uninstall_keycloak() {
  echo "Removing per-instance Keycloak client for namespace ${NAMESPACE}..."

  local client_id="rhdh-client-${NAMESPACE}"

  if _keycloak_ensure_ready 2>/dev/null; then
    local client_uuid
    client_uuid=$(_keycloak_api_call GET \
      "${KEYCLOAK_URL}/admin/realms/rhdh/clients?clientId=${client_id}" \
      "" "Get client UUID" | jq -r '.[0].id // empty')

    if [[ -n "$client_uuid" ]]; then
      _keycloak_api_call DELETE \
        "${KEYCLOAK_URL}/admin/realms/rhdh/clients/${client_uuid}" \
        "" "Delete client '${client_id}'" >/dev/null \
        && echo "  Deleted OIDC client: ${client_id}" \
        || echo "  Warning: Failed to delete OIDC client: ${client_id}"
    else
      echo "  Client '${client_id}' not found in Keycloak — nothing to delete."
    fi
  else
    echo "  Warning: Could not reach Keycloak — skipping client deletion."
  fi

  echo "Per-instance Keycloak teardown complete for ${NAMESPACE}."
}

# =============================================================================
# Teardown: full shared Keycloak infra (only when all instances are gone)
# =============================================================================
uninstall_keycloak_infra() {
  echo "Uninstalling shared Keycloak infrastructure from ${KEYCLOAK_NS}..."

  helm uninstall "${_KEYCLOAK_RELEASE_NAME}" --namespace "${KEYCLOAK_NS}" 2>/dev/null || true
  oc delete route "${_KEYCLOAK_RELEASE_NAME}" --namespace "${KEYCLOAK_NS}" 2>/dev/null || true
  oc delete secret keycloak-credentials --namespace "${KEYCLOAK_NS}" 2>/dev/null || true
  oc delete secret keycloak-test-credentials --namespace "${KEYCLOAK_NS}" 2>/dev/null || true
  oc delete pvc "data-${_KEYCLOAK_RELEASE_NAME}-postgresql-0" \
    --namespace "${KEYCLOAK_NS}" 2>/dev/null || true

  echo "Shared Keycloak uninstalled from ${KEYCLOAK_NS}!"
  echo "To also delete the namespace: oc delete project ${KEYCLOAK_NS}"
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
  echo "Configuring Keycloak"
  echo "  Shared Keycloak NS:  ${KEYCLOAK_NS}"
  echo "  RHDH instance NS:   ${NAMESPACE}"
  echo "=============================================="

  deploy_keycloak
  create_users_and_groups_keycloak
  register_keycloak_client
  config_secrets_for_keycloak_plugins
  apply_keycloak_labels

  echo ""
  echo "=============================================="
  echo "Keycloak URL:   ${KEYCLOAK_URL}"
  echo "Admin:          admin"
  echo "Realm:          rhdh"
  echo "Client ID:      rhdh-client-${NAMESPACE}"
  echo "User pass:      <username>@123"
  echo "Keycloak configuration complete!"
  echo "=============================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
