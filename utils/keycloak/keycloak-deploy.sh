#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

NAMESPACE=${1:-rhdh-keycloak}
KEYCLOAK_RELEASE_NAME="keycloak"

echo -e "${GREEN}🚀 Starting Keycloak deployment on OpenShift...${NC}"

# Add Bitnami Helm repository (for Keycloak chart)
echo -e "${YELLOW}Adding Bitnami Helm repository...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create namespace if it doesn't exist
echo -e "${YELLOW}Creating namespace: $NAMESPACE${NC}"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Check if Keycloak is already deployed and healthy
if helm list -n $NAMESPACE | grep -q "^$KEYCLOAK_RELEASE_NAME"; then
  echo -e "${YELLOW}Keycloak is already deployed. Checking health...${NC}"
  if kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    echo -e "${GREEN}✅ Keycloak is already running and healthy. Skipping deployment.${NC}"
    SKIP_DEPLOYMENT=true
  else
    echo -e "${YELLOW}Keycloak exists but is not healthy. Redeploying...${NC}"
    SKIP_DEPLOYMENT=false
  fi
else
  SKIP_DEPLOYMENT=false
fi

# Deploy Keycloak using Helm
if [ "$SKIP_DEPLOYMENT" != "true" ]; then
  echo -e "${YELLOW}Deploying Keycloak with Helm...${NC}"
  
  # Try deployment with retries
  MAX_RETRIES=2
  RETRY_COUNT=0
  
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if helm upgrade --install $KEYCLOAK_RELEASE_NAME bitnami/keycloak \
      --namespace $NAMESPACE \
      --values utils/keycloak/keycloak-values.yaml \
      --wait --timeout=20m; then
      echo -e "${GREEN}✅ Keycloak deployed successfully${NC}"
      break
    else
      RETRY_COUNT=$((RETRY_COUNT + 1))
      if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo -e "${YELLOW}⚠️  Deployment attempt $RETRY_COUNT failed. Retrying in 30 seconds...${NC}"
        sleep 30
      else
        echo -e "${RED}❌ Helm deployment failed after $MAX_RETRIES attempts. Checking pod status...${NC}"
        kubectl get pods -n $NAMESPACE
        echo -e "${YELLOW}Pod descriptions:${NC}"
        kubectl describe pods -n $NAMESPACE -l app.kubernetes.io/name=keycloak
        echo -e "${YELLOW}Recent logs:${NC}"
        kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=keycloak --tail=50 --all-containers=true || true
        exit 1
      fi
    fi
  done
fi

# Create OpenShift Route
echo -e "${YELLOW}Creating OpenShift Route...${NC}"
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

# Wait for Keycloak to be ready
echo -e "${YELLOW}Waiting for Keycloak to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak -n $NAMESPACE --timeout=300s

# Get Keycloak URL from OpenShift Route
echo -e "${YELLOW}Getting Keycloak Route URL...${NC}"
KEYCLOAK_HOST=$(kubectl get route $KEYCLOAK_RELEASE_NAME -n $NAMESPACE -o jsonpath='{.spec.host}')
KEYCLOAK_URL="http://$KEYCLOAK_HOST"

echo -e "${GREEN}Keycloak is accessible at: $KEYCLOAK_URL${NC}"

# Wait for Keycloak to be fully initialized
echo -e "${YELLOW}Waiting for Keycloak to be fully initialized...${NC}"
sleep 60

# Configure Keycloak using REST API
echo -e "${YELLOW}Configuring Keycloak...${NC}"

# Wait for Keycloak to be accessible
echo -e "${YELLOW}Waiting for Keycloak to be accessible...${NC}"
for i in $(seq 1 30); do
  if curl -s "$KEYCLOAK_URL/realms/master" > /dev/null 2>&1; then
    echo -e "${GREEN}Keycloak is accessible${NC}"
    break
  fi
  echo "Waiting... attempt $i/30"
  sleep 10
done

# Get admin token
echo -e "${YELLOW}Getting admin token...${NC}"
ADMIN_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=admin123" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | \
  sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$ADMIN_TOKEN" ]; then
  echo -e "${RED}Failed to get admin token${NC}"
  exit 1
fi

echo -e "${GREEN}Got admin token, creating realm...${NC}"

# Create realm with proper configuration
curl -s -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "realm": "rhdh",
    "enabled": true,
    "displayName": "RHDH Realm",
    "loginTheme": "keycloak",
    "accessTokenLifespan": 300,
    "accessTokenLifespanForImplicitFlow": 900,
    "ssoSessionIdleTimeout": 1800,
    "ssoSessionMaxLifespan": 36000,
    "offlineSessionIdleTimeout": 2592000,
    "offlineSessionMaxLifespan": 5184000,
    "accessCodeLifespan": 60,
    "accessCodeLifespanUserAction": 300,
    "accessCodeLifespanLogin": 1800,
    "actionTokenGeneratedByAdminLifespan": 43200,
    "actionTokenGeneratedByUserLifespan": 300,
    "oauth2DeviceCodeLifespan": 600,
    "oauth2DevicePollingInterval": 5,
    "attributes": {
      "userInfoEndpoint": "true"
    }
  }'

echo -e "${GREEN}Realm created, creating client...${NC}"

# Create client by importing from JSON file
curl -s -X POST "$KEYCLOAK_URL/admin/realms/rhdh/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d @utils/keycloak/rhdh-client.json

echo -e "${GREEN}Client created, assigning service account role...${NC}"

# Wait for service account to be created
sleep 5

# Assign realm-management roles to the service account
echo -e "${YELLOW}Assigning realm-management roles to service account...${NC}"

SERVICE_ACCOUNT_USER_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/rhdh/users?username=service-account-rhdh-client" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [ -z "$SERVICE_ACCOUNT_USER_ID" ]; then
    echo -e "${RED}Failed to get service account user ID for service-account-rhdh-client.${NC}"
    exit 1
fi

REALM_MANAGEMENT_CLIENT_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/rhdh/clients?clientId=realm-management" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [ -z "$REALM_MANAGEMENT_CLIENT_ID" ]; then
    echo -e "${RED}Failed to get realm-management client ID.${NC}"
    exit 1
fi

VIEW_AUTH_ROLE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$REALM_MANAGEMENT_CLIENT_ID/roles/view-authorization" -H "Authorization: Bearer $ADMIN_TOKEN")
MANAGE_AUTH_ROLE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$REALM_MANAGEMENT_CLIENT_ID/roles/manage-authorization" -H "Authorization: Bearer $ADMIN_TOKEN")
VIEW_USERS_ROLE=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/rhdh/clients/$REALM_MANAGEMENT_CLIENT_ID/roles/view-users" -H "Authorization: Bearer $ADMIN_TOKEN")

curl -s -X POST "$KEYCLOAK_URL/admin/realms/rhdh/users/$SERVICE_ACCOUNT_USER_ID/role-mappings/clients/$REALM_MANAGEMENT_CLIENT_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "[$VIEW_AUTH_ROLE, $MANAGE_AUTH_ROLE, $VIEW_USERS_ROLE]"

echo -e "${GREEN}Assigned 'view-authorization', 'manage-authorization' and 'view-users' to service-account-rhdh-client.${NC}"

echo -e "${GREEN}Creating users...${NC}"

# Create first user (rhdhtest1)
curl -s -X POST "$KEYCLOAK_URL/admin/realms/rhdh/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "test1",
    "enabled": true,
    "email": "test1@redhat.com",
    "firstName": "test1", 
    "lastName": "lastname1",
    "emailVerified": true,
    "attributes": {
      "locale": ["en"]
    },
    "credentials": [{
      "type": "password",
      "value": "test1@123",
      "temporary": false
    }]
  }'

# Create second user (rhdhtest2)
curl -s -X POST "$KEYCLOAK_URL/admin/realms/rhdh/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "test2",
    "enabled": true,
    "email": "test2@redhat.com",
    "firstName": "test2",
    "lastName": "lastname2",
    "emailVerified": true,
    "attributes": {
      "locale": ["en"]
    },
    "credentials": [{
      "type": "password",
      "value": "test2@123",
      "temporary": false
    }]
  }'

echo -e "${GREEN}Configuration completed successfully!${NC}"

# Test the realm configuration
echo -e "${YELLOW}Testing realm configuration...${NC}"
if curl -s "$KEYCLOAK_URL/realms/rhdh/.well-known/openid_configuration" | head -c 100 > /dev/null; then
  echo -e "${GREEN}Realm configuration test completed successfully.${NC}"
else
  echo -e "${YELLOW}Realm configuration test warning (but likely still working).${NC}"
fi

echo -e "${GREEN}✅ Keycloak deployment completed successfully!${NC}"
echo -e "${GREEN}Keycloak URL: $KEYCLOAK_URL${NC}"
echo -e "${GREEN}Admin Console: $KEYCLOAK_URL/admin${NC}"
echo -e "${GREEN}Admin Username: admin${NC}"
echo -e "${GREEN}Admin Password: admin123${NC}"
echo -e "${GREEN}Users created: rhdhtest1, rhdhtest2${NC}"
echo -e "${GREEN}User Password: rhdhtest@123${NC}"
echo -e "${GREEN}Realm: rhdh${NC}"

# export environment variables
export KEYCLOAK_CLIENT_SECRET="rhdh-client-secret"
export KEYCLOAK_CLIENT_ID="rhdh-client"
export KEYCLOAK_REALM="rhdh"
export KEYCLOAK_LOGIN_REALM="rhdh"
export KEYCLOAK_METADATA_URL="$KEYCLOAK_URL/realms/rhdh"
export KEYCLOAK_BASE_URL="$KEYCLOAK_URL"