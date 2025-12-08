#!/bin/bash
set -e

# Check if the required parameters are provided
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <namespace> <version>"
    exit 1
fi

namespace="$1"
version="$2"
github=0 # by default don't use the Github repo unless the chart doesn't exist in the OCI registry

# Get cluster router base
export CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')

# Validate version and determine chart version
if [[ "$version" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    CV=$(curl -s "https://quay.io/api/v1/repository/rhdh/chart/tag/?onlyActiveTags=true&limit=600" | jq -r '.tags[].name' | grep "^${version}-" | sort -V | tail -n 1)
elif [[ "$version" =~ CI$ ]]; then
    CV=$version
else
    echo "Error: Invalid helm chart version: $version"
    [[ "$OPENSHIFT_CI" == "true" ]] && gh_comment "❌ **Error: Invalid helm chart version** 🚫\n\n📝 **Provided version:** \`$version\`\n\nPlease check your version and try again! 🔄"
    exit 1
fi

echo "Using Helm chart version: ${CV}"

CHART_URL="oci://quay.io/rhdh/chart"
if ! helm show chart $CHART_URL --version $CV &> /dev/null; then github=1; fi
if [[ $github -eq 1 ]]; then
    CHART_URL="https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/charts/redhat/redhat/redhat-developer-hub/${CV}/redhat-developer-hub-${CV}.tgz"
    oc apply -f "https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/installation/rhdh-next-ci-repo.yaml"
fi

echo "Using ${CHART_URL} to install Helm chart"

# RHDH URL
export RHDH_BASE_URL="http://redhat-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"

# Apply secrets
envsubst < config/rhdh-secrets.yaml | oc apply -f - --namespace="$namespace"

# Install/upgrade Helm chart
helm upgrade redhat-developer-hub -i "${CHART_URL}" --version "$CV" \
    -f "helm/value_file.yaml" \
    -f <(echo "global:"; echo "  dynamic:"; cat config/dynamic-plugins.yaml | sed 's/^/    /') \
    --set global.clusterRouterBase="${CLUSTER_ROUTER_BASE}" \
    --namespace="$namespace"

# Restart the deployment to ensure fresh pods
oc rollout restart deployment/redhat-developer-hub -n "$namespace"
