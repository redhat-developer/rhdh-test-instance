#!/bin/bash
set -e

NAMESPACE=${1:-rhdh-keycloak}
USERS_FILE=${2:-utils/keycloak/users.json}
GROUPS_FILE=${3:-utils/keycloak/groups.json}
CLIENT_FILE="utils/keycloak/rhdh-client.json"

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

[ ! -f "$CLIENT_FILE" ] && echo "Error: Client configuration file not found: $CLIENT_FILE" && exit 1

# Create namespace and deploy Keycloak
echo "Creating namespace $NAMESPACE..."
oc create namespace $NAMESPACE --dry-run=client -o yaml | oc apply -f -

echo "Deploying Keycloak..."
oc process -f https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/tags/25.0.0/openshift/keycloak.yaml \
  -p KEYCLOAK_ADMIN=admin \
  -p KEYCLOAK_ADMIN_PASSWORD=admin \
  -p NAMESPACE=$NAMESPACE \
| oc apply -n $NAMESPACE -f -

echo "Waiting for Keycloak rollout..."
oc rollout status deploymentconfig/keycloak -n $NAMESPACE --timeout=5m

KEYCLOAK_URL="https://$(oc get route keycloak -n $NAMESPACE -o jsonpath='{.spec.host}')"
[ -z "$KEYCLOAK_URL" ] || [ "$KEYCLOAK_URL" = "https://" ] && echo "Error: Failed to get Keycloak route" && exit 1
echo "Keycloak URL: $KEYCLOAK_URL"

# Wait for Keycloak API to be ready
echo "Waiting for Keycloak API..."
TIMEOUT=300
ELAPSED=0
until curl -sk "$KEYCLOAK_URL/realms/master" &>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  [ $ELAPSED -ge $TIMEOUT ] && echo "Error: Keycloak API not ready after 5 minutes" && exit 1
done

# Get admin token
TOKEN_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=admin&grant_type=password&client_id=admin-cli")
TOKEN_HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')
[ "$TOKEN_HTTP_CODE" -ge 400 ] && echo "Error: Failed to get admin token (HTTP $TOKEN_HTTP_CODE): $TOKEN_BODY" && exit 1
ADMIN_TOKEN=$(echo "$TOKEN_BODY" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -z "$ADMIN_TOKEN" ] && echo "Error: Failed to parse admin token" && exit 1

# Create realm and client
echo "Creating realm 'rhdh'..."
api_call POST "$KEYCLOAK_URL/admin/realms" \
  '{"realm":"rhdh","enabled":true,"displayName":"RHDH Realm"}' \
  "Create realm" >/dev/null

echo "Creating client..."
api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/clients" \
  "$(cat "$CLIENT_FILE")" \
  "Create client" >/dev/null

# Get IDs for role assignment
SERVICE_ACCOUNT_RESPONSE=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/users?username=service-account-rhdh-client" "" "Get service account")
SERVICE_ACCOUNT_ID=$(echo "$SERVICE_ACCOUNT_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
[ -z "$SERVICE_ACCOUNT_ID" ] && echo "Error: Service account not found" && exit 1

REALM_MGMT_RESPONSE=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients?clientId=realm-management" "" "Get realm-management client")
REALM_MGMT_ID=$(echo "$REALM_MGMT_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
[ -z "$REALM_MGMT_ID" ] && echo "Error: realm-management client not found" && exit 1

ROLES_RESPONSE=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$REALM_MGMT_ID/roles" "" "Get roles")
ROLES=$(echo "$ROLES_RESPONSE" | \
  sed 's/},/}\n/g' | grep -E '"name":"(view-authorization|manage-authorization|view-users)"' | \
  tr '\n' ',' | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')
[ -z "$ROLES" ] || [ "$ROLES" = "[]" ] && echo "Error: Required roles not found" && exit 1

echo "Assigning service account roles..."
api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/users/$SERVICE_ACCOUNT_ID/role-mappings/clients/$REALM_MGMT_ID" \
  "$ROLES" \
  "Assign roles" >/dev/null

# Create groups
if [ -f "$GROUPS_FILE" ]; then
  echo "Creating groups..."
  for group in $(cat "$GROUPS_FILE" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p'); do
    api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/groups" \
      "{\"name\":\"$group\"}" \
      "Create group '$group'" >/dev/null && echo "  Created group: $group" || echo "  Warning: Failed to create group: $group"
  done
fi

# Create users
if [ -f "$USERS_FILE" ]; then
  echo "Creating users..."

  python3 -c "
import json
with open('$USERS_FILE') as f:
    users = json.load(f)
for u in users:
    print(json.dumps(u))
" | while read -r user_json; do
    username=$(echo "$user_json" | sed -n 's/.*\"username\": *"\([^"]*\)".*/\1/p')
    groups=$(echo "$user_json" | python3 -c "import sys,json; u=json.loads(sys.stdin.read()); print(','.join(u.get('groups',[])))" 2>/dev/null || echo "")
    user_payload=$(echo "$user_json" | python3 -c "import sys,json; u=json.loads(sys.stdin.read()); u.pop('groups',None); print(json.dumps(u))")

    if ! api_call POST "$KEYCLOAK_URL/admin/realms/rhdh/users" "$user_payload" "Create user '$username'" >/dev/null; then
      echo "  Warning: Failed to create user: $username"
      continue
    fi
    echo "  Created user: $username"

    # Add user to groups
    if [ -n "$groups" ]; then
      USER_ID=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/users?username=$username" "" "Get user ID" | \
        sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
      [ -z "$USER_ID" ] && echo "    Warning: Could not get user ID, skipping groups" && continue

      for group in $(echo "$groups" | tr ',' ' '); do
        GROUP_ID=$(api_call GET "$KEYCLOAK_URL/admin/realms/rhdh/groups?search=$group" "" "Get group ID" | \
          sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
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
echo "Admin: admin/admin"
echo "Realm: rhdh"

export KEYCLOAK_CLIENT_SECRET="rhdh-client-secret"
export KEYCLOAK_CLIENT_ID="rhdh-client"
export KEYCLOAK_REALM="rhdh"
export KEYCLOAK_LOGIN_REALM="rhdh"
export KEYCLOAK_METADATA_URL="$KEYCLOAK_URL/realms/rhdh"
export KEYCLOAK_BASE_URL="$KEYCLOAK_URL"
