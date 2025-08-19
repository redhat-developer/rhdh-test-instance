#!/bin/bash
set -e

# Default values
namespace="rhdh"
installation_method=""
CV=""
github=0 # by default don't use the Github repo unless the chart doesn't exist in the OCI registry

# Parse positional arguments
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <installation-method> <version>"
    echo "Installation methods: helm, operator"
    echo "Examples:"
    echo "  $0 helm 1.5-171-CI"
    echo "  $0 helm next"
    echo "  $0 operator 1.5"
    exit 1
fi

installation_method="$1"
version="$2"

# Validate installation method
if [[ "$installation_method" != "helm" && "$installation_method" != "operator" ]]; then
    echo "Error: Installation method must be either 'helm' or 'operator'"
    echo "Usage: $0 <installation-method> <version>"
    [[ "$OPENSHIFT_CI" == "true" ]] && gh_comment "❌ **Error: Invalid installation method** 🚫\n\n📝 **Provided installation method:** \`$installation_method\`\n\nInstallation method must be either 'helm' or 'operator' 🔄"
    exit 1
fi

# Deploy Keycloak with users and roles.
# comment this out if you don't want to deploy Keycloak or use your own Keycloak instance.
# source utils/keycloak/keycloak-deploy.sh $namespace

[[ "${OPENSHIFT_CI}" != "true" ]] && source .env
# source utils/utils.sh

# Create or switch to the specified namespace
oc new-project "$namespace" || oc project "$namespace"

# Create configmap with environment variables substituted
oc create configmap app-config-rhdh \
    --from-file="config/app-config-rhdh.yaml" \
    --namespace="$namespace" \
    --dry-run=client -o yaml | oc apply -f - --namespace="$namespace"

export CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')

if [[ "$installation_method" == "helm" ]]; then
    source helm/deploy.sh "$namespace" "$version"
else
    source operator/deploy.sh "$namespace" "$version"
fi

# Wait for the deployment to be ready
oc rollout status deployment -l app.kubernetes.io/instance=developer-hub -n "$namespace" --timeout=300s || echo "Error: Timed out waiting for deployment to be ready."

echo "
RHDH_BASE_URL : 
$RHDH_BASE_URL
"