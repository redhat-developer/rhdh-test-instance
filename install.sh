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
CV="$2"

# Validate installation method
if [[ "$installation_method" != "helm" && "$installation_method" != "operator" ]]; then
    echo "Error: Installation method must be either 'helm' or 'operator'"
    echo "Usage: $0 <installation-method> <version>"
    exit 1
fi

[[ "${OPENSHIFT_CI}" == "false" ]] && source .env
# source utils/utils.sh

# Create or switch to the specified namespace
oc new-project "$namespace" || oc project "$namespace"

# Create configmap with environment variables substituted
oc create configmap app-config-rhdh \
    --from-file="config/app-config-rhdh.yaml" \
    --namespace="$namespace" \
    --dry-run=client -o yaml | oc apply -f - --namespace="$namespace"

export CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')


CHART_URL="oci://quay.io/rhdh/chart"
if ! helm show chart $CHART_URL --version $CV &> /dev/null; then github=1; fi
if [[ $github -eq 1 ]]; then
    CHART_URL="https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/charts/redhat/redhat/redhat-developer-hub/${CV}/redhat-developer-hub-${CV}.tgz"
    oc apply -f "https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/installation/rhdh-next-ci-repo.yaml"
fi

echo "Using ${CHART_URL} to install Helm chart"

# RHDH URL
export RHDH_BASE_URL="https://redhat-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"

# Apply secrets
envsubst < config/rhdh-secrets.yaml | oc apply -f - --namespace="$namespace"

# Install/upgrade Helm chart
helm upgrade redhat-developer-hub -i "${CHART_URL}" --version "$CV" \
    -f "helm/value_file.yaml" \
    -f <(echo "global:"; echo "  dynamic:"; cat config/dynamic-plugins.yaml | sed 's/^/    /') \
    --set global.clusterRouterBase="${CLUSTER_ROUTER_BASE}"


oc wait --for=condition=Ready pod --all -n "$namespace" --timeout=300s || echo "Error: Timed out waiting for pods to be ready."

echo "
RHDH_BASE_URL : 
$RHDH_BASE_URL
"