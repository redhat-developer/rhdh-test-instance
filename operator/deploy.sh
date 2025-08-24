#!/bin/bash
set -e

# Parse arguments
namespace="$1"
version="$2"

if [[ -z "$namespace" || -z "$version" ]]; then
    echo "Usage: $0 <namespace> <version>"
    exit 1
fi

curl -LO https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/release-$version/.rhdh/scripts/install-rhdh-catalog-source.sh
chmod +x install-rhdh-catalog-source.sh
./install-rhdh-catalog-source.sh -v $version --install-operator rhdh
rm install-rhdh-catalog-source.sh

export RHDH_BASE_URL="https://backstage-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"

# Apply secrets
envsubst < config/rhdh-secrets.yaml | oc apply -f - --namespace="$namespace"

oc create configmap dynamic-plugins \
    --from-file="config/dynamic-plugins.yaml" \
    --namespace="$namespace" \
    --dry-run=client -o yaml | oc apply -f -

timeout 300 bash -c '
while ! oc get crd/backstages.rhdh.redhat.com -n "${namespace}" >/dev/null 2>&1; do
    echo "Waiting for Backstage CRD to be created..."
    sleep 20
done
echo "Backstage CRD is created."
' || echo "Error: Timed out waiting for Backstage CRD creation."

oc apply -f "operator/subscription.yaml" -n "$namespace"
