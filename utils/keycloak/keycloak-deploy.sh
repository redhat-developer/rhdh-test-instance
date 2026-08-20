#!/bin/bash
set -e

# Check for required dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed"; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "Error: oc (OpenShift CLI) is required but not installed"; exit 1; }

NAMESPACE=${1:-rhdh-keycloak}
USERS_FILE=${2:-utils/keycloak/users.json}
GROUPS_FILE=${3:-utils/keycloak/groups.json}
CLIENT_FILE="utils/keycloak/rhdh-client.json"
KEYCLOAK_RELEASE_NAME="keycloak"

# Helper function for API calls with error checking
api_call() {
  local method=$1
  local url=$2
  local data=$3
  local description=$4

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

  # 409 Conflict is acceptable for create operations (already exists)
  if [ "$HTTP_CODE" = "409" ]; then
    echo "Warning: $description - already exists (continuing)" >&2
    echo "$BODY"
    return 0
  fi

  echo "Error: $description failed (HTTP $HTTP_CODE): $BODY" >&2
  return 1
}

# Validate JSON files exist and are valid
[ ! -f "$CLIENT_FILE" ] && echo "Error: Client configuration file not found: $CLIENT_FILE" && exit 1
jq empty "$CLIENT_FILE" 2>/dev/null || { echo "Error: Invalid JSON in $CLIENT_FILE"; exit 1; }
[ -f "$USERS_FILE" ] && { jq empty "$USERS_FILE" 2>/dev/null || { echo "Error: Invalid JSON in $USERS_FILE"; exit 1; }; }
[ -f "$GROUPS_FILE" ] && { jq empty "$GROUPS_FILE" 2>/dev/null || { echo "Error: Invalid JSON in $GROUPS_FILE"; exit 1; }; }

# Create namespace and deploy Keycloak
echo "Creating namespace $NAMESPACE..."
oc create namespace $NAMESPACE --dry-run=client -o yaml | oc apply -f -

echo "Adding Bitnami Helm repository..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

echo "Deploying Keycloak..."
helm upgrade --install $KEYCLOAK_RELEASE_NAME bitnami/keycloak \
  --namespace $NAMESPACE \
  --values utils/keycloak/keycloak-values.yaml

echo "Waiting for Keycloak rollout..."
oc rollout status statefulset/keycloak -n $NAMESPACE --timeout=5m

# Detect TLS based on cluster route configuration
if oc get route console -n openshift-console -o=jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
    KEYCLOAK_PROTOCOL="https"
else
    KEYCLOAK_PROTOCOL="http"
fi

# Create OpenShift Route
echo "Creating OpenShift Route (protocol: $KEYCLOAK_PROTOCOL)..."
if [ "$KEYCLOAK_PROTOCOL" = "https" ]; then
cat <<EOF | kubectl apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $KEYCLOAK_RELEASE_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/instance: $KEYCLOAK_RELEASE_NAME
spec:
  to:
    kind: Service
    name: $KEYCLOAK_RELEASE_NAME
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
else
cat <<EOF | kubectl apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $KEYCLOAK_RELEASE_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/instance: $KEYCLOAK_RELEASE_NAME
spec:
  to:
    kind: Service
    name: $KEYCLOAK_RELEASE_NAME
    weight: 100
  port:
    targetPort: http
  wildcardPolicy: None
EOF
fi

KEYCLOAK_URL="${KEYCLOAK_PROTOCOL}://$(oc get route keycloak -n $NAMESPACE -o jsonpath='{.spec.host}')"
[ -z "$KEYCLOAK_URL" ] || [ "$KEYCLOAK_URL" = "${KEYCLOAK_PROTOCOL}://" ] && echo "Error: Failed to get Keycloak route" && exit 1
echo "Keycloak URL: $KEYCLOAK_URL"

# Wait for Keycloak API to be ready (check for HTTP 200, not just connection)
echo "Waiting for Keycloak API..."
TIMEOUT=300
ELAPSED=0
while true; do
  HTTP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL/realms/master" 2>/dev/null || echo "000")
  if [ "$HTTP_STATUS" = "200" ]; then
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "Error: Keycloak API not ready after 5 minutes (last status: $HTTP_STATUS)"
    exit 1
  fi
  echo "  Waiting... (status: $HTTP_STATUS)"
done

# Get admin token
TOKEN_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=admin123&grant_type=password&client_id=admin-cli")
TOKEN_HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')
[ "$TOKEN_HTTP_CODE" -ge 400 ] && echo "Error: Failed to get admin token (HTTP $TOKEN_HTTP_CODE): $TOKEN_BODY" && exit 1
ADMIN_TOKEN=$(echo "$TOKEN_BODY" | jq -r '.access_token // empty')
[ -z "$ADMIN_TOKEN" ] && echo "Error: Failed to parse admin token" && exit 1

# Create realm and client
echo "Creating realm 'rhdh'..."
api_call POST "$KEYCLOAK_URL/admin/realms" \
  '{"realm":"rhdh","enabled":true,"displayName":"RHDH Realm"}' \
  "Create realm" >/dev/null

echo "Creating client..."
api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/clients" \
  "$(jq -c '.' "$CLIENT_FILE")" \
  "Create client" >/dev/null

# Get IDs for role assignment
SERVICE_ACCOUNT_ID=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/users?username=service-account-rhdh-client" "" "Get service account" | \
  jq -r '.[0].id // empty')
[ -z "$SERVICE_ACCOUNT_ID" ] && echo "Error: Service account not found" && exit 1

REALM_MGMT_ID=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients?clientId=realm-management" "" "Get realm-management client" | \
  jq -r '.[0].id // empty')
[ -z "$REALM_MGMT_ID" ] && echo "Error: realm-management client not found" && exit 1

ROLES=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$REALM_MGMT_ID/roles" "" "Get roles" | \
  jq -c '[.[] | select(.name == "view-authorization" or .name == "manage-authorization" or .name == "view-users")]')
[ -z "$ROLES" ] || [ "$ROLES" = "[]" ] && echo "Error: Required roles not found" && exit 1

echo "Assigning service account roles..."
api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/users/$SERVICE_ACCOUNT_ID/role-mappings/clients/$REALM_MGMT_ID" \
  "$ROLES" \
  "Assign roles" >/dev/null

# Create groups
if [ -f "$GROUPS_FILE" ]; then
  echo "Creating groups..."
  jq -r '.[].name' "$GROUPS_FILE" | while read -r group; do
    api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/groups" \
      "{\"name\":\"$group\"}" \
      "Create group '$group'" >/dev/null && echo "  Created group: $group" || echo "  Warning: Failed to create group: $group"
  done
fi

# Create users
if [ -f "$USERS_FILE" ]; then
  echo "Creating users..."

  jq -c '.[]' "$USERS_FILE" | while read -r user_json; do
    username=$(echo "$user_json" | jq -r '.username')
    groups=$(echo "$user_json" | jq -r '.groups // [] | join(",")')
    user_payload=$(echo "$user_json" | jq -c 'del(.groups)')

    if ! api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/users" "$user_payload" "Create user '$username'" >/dev/null; then
      echo "  Warning: Failed to create user: $username"
      continue
    fi
    echo "  Created user: $username"

    # Add user to groups
    if [ -n "$groups" ]; then
      USER_ID=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/users?username=$username" "" "Get user ID" | \
        jq -r '.[0].id // empty')
      [ -z "$USER_ID" ] && echo "    Warning: Could not get user ID, skipping groups" && continue

      for group in $(echo "$groups" | tr ',' ' '); do
        GROUP_ID=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/groups?search=$group" "" "Get group ID" | \
          jq -r '.[0].id // empty')
        [ -z "$GROUP_ID" ] && echo "    Warning: Group '$group' not found" && continue
        api_call PUT "$KEYCLOAK_URL/admin/realms/rhdh/users/$USER_ID/groups/$GROUP_ID" "" "Add to group" >/dev/null \
          && echo "    Added to group: $group" || echo "    Warning: Failed to add to group: $group"
      done
    fi
  done
fi

echo ""
echo "========================================="
echo "Keycloak deployment complete"
echo "========================================="
echo "URL: $KEYCLOAK_URL"
echo "Admin: admin/admin123"
echo "Realm: rhdh"

export KEYCLOAK_CLIENT_SECRET="rhdh-client-secret"
export KEYCLOAK_CLIENT_ID="rhdh-client"
export KEYCLOAK_REALM="rhdh"
export KEYCLOAK_LOGIN_REALM="rhdh"
export KEYCLOAK_METADATA_URL="$KEYCLOAK_URL/realms/rhdh"
export KEYCLOAK_BASE_URL="$KEYCLOAK_URL"
