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

# Validate version and determine chart version
if [[ "$version" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    CV=$(curl -s "https://quay.io/api/v1/repository/rhdh/chart/tag/?onlyActiveTags=true&limit=600" | jq -r '.tags[].name' | grep "^${version}-" | sort -V | tail -n 1)
elif [[ "$version" =~ CI$ ]]; then
    CV=$version
elif [[ "$version" == "next" ]]; then
    CV=$(curl -s "https://quay.io/api/v1/repository/rhdh/chart/tag/?onlyActiveTags=true&limit=600" | jq -r '.tags[].name' | grep -- '-CI$' | sort -V | tail -n 1)
    if [[ -z "$CV" ]]; then
        CV="next"
    fi
else
    echo "Error: Invalid helm chart version: $version"
    [[ "$OPENSHIFT_CI" == "true" ]] && gh_comment "❌ **Error: Invalid helm chart version** 🚫\n\n📝 **Provided version:** \`$version\`\n\nPlease check your version and try again! 🔄"
    exit 1
fi

echo "Using Helm chart version: ${CV}"

# Catalog index tag defaults to the major.minor version, or "next" for next
if [[ "$version" == "next" ]]; then
    CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-next}"
else
    CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-$(echo "$version" | grep -oE '^[0-9]+\.[0-9]+')}"
fi
echo "Using catalog index tag: ${CATALOG_INDEX_TAG}"

CHART_URL="oci://quay.io/rhdh/chart"
if ! helm show chart $CHART_URL --version $CV &> /dev/null; then github=1; fi
if [[ $github -eq 1 ]]; then
    CHART_URL="https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/charts/redhat/redhat/redhat-developer-hub/${CV}/redhat-developer-hub-${CV}.tgz"
    oc apply -f "https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/installation/rhdh-next-ci-repo.yaml"
fi

echo "Using ${CHART_URL} to install Helm chart"

append_to_dynamic_plugins_cm() {
    local extra="$1"
    local current
    current="$(oc get configmap dynamic-plugins --namespace "$namespace" -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || true)"
    extra="$(printf '%s\n' "$extra" | sed '1{/^plugins:[[:space:]]*$/d;}')"
    if [[ "$extra" == -* ]]; then
        extra="$(printf '%s\n' "$extra" | sed 's/^/  /')"
    fi
    oc create configmap dynamic-plugins \
        --from-file=dynamic-plugins.yaml=<(printf '%s\n%s\n' "$current" "$extra") \
        --namespace "$namespace" --dry-run=client -o yaml \
        | oc apply -f - --namespace "$namespace" >/dev/null
}

if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    current_dp="$(oc get configmap dynamic-plugins --namespace "$namespace" -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || true)"
    if [[ "$current_dp" != *plugin-orchestrator* ]]; then
        orch_file="config/orchestrator-dynamic-plugins.yaml"
        if [[ "$version" == "next" || "$version" == *-CI ]]; then
            orch_file="config/orchestrator-dynamic-plugins-next.yaml"
        fi
        echo "Merging orchestrator plugins from ${orch_file} into dynamic-plugins ConfigMap..."
        append_to_dynamic_plugins_cm "$(cat "$orch_file")"
    fi
fi

# Install orchestrator infrastructure if requested
if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    if [[ "${SKIP_ORCHESTRATOR_INFRA_INSTALL:-}" == "1" ]]; then
        echo "Skipping orchestrator infrastructure chart installation (SKIP_ORCHESTRATOR_INFRA_INSTALL=1)."
    else
    echo "Installing orchestrator infrastructure chart..."
    # Check if operators are already installed on the cluster (cluster-scoped, shared across namespaces)
    if oc get pods -n openshift-serverless --no-headers 2>/dev/null | grep -q . && \
       oc get pods -n openshift-serverless-logic --no-headers 2>/dev/null | grep -q .; then
        echo "Serverless operators already running on cluster, skipping infra chart."
    else
        INFRA_ARGS=(--version "$CV" --namespace "$namespace"
            --wait --timeout=5m
            --set serverlessLogicOperator.subscription.spec.installPlanApproval=Automatic
            --set serverlessOperator.subscription.spec.installPlanApproval=Automatic)
        # Skip CRDs if they already exist (e.g. installed by OLM)
        if oc get crd knativeservings.operator.knative.dev &>/dev/null; then
            INFRA_ARGS+=(--skip-crds)
        fi
        helm install orchestrator-infra oci://quay.io/rhdh/orchestrator-infra-chart "${INFRA_ARGS[@]}"
        echo "Orchestrator infrastructure chart installed successfully."
    fi

    # Wait for operator pods to appear
    echo "Waiting for serverless operator pods..."
    until [[ "$(oc get pods -n openshift-serverless --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do sleep 5; done
    until [[ "$(oc get pods -n openshift-serverless-logic --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do sleep 5; done
    echo "Serverless operator pods are running."
    fi
fi

# Build dynamic plugins value file.
# Read from the cluster ConfigMap seeded in deploy.sh and augmented by any
# plugin setup scripts. Fall back to config/dynamic-plugins.yaml if the
# ConfigMap is not available (e.g. standalone helm/deploy.sh execution).
DYNAMIC_PLUGINS_FILE=$(mktemp)
trap "rm -f $DYNAMIC_PLUGINS_FILE" EXIT
echo "global:" > "$DYNAMIC_PLUGINS_FILE"
echo "  dynamic:" >> "$DYNAMIC_PLUGINS_FILE"
# Escape {{inherit}} for Helm's Go template engine: {{inherit}} -> {{ "{{inherit}}" }}
if oc get configmap dynamic-plugins --namespace "$namespace" &>/dev/null; then
    oc get configmap dynamic-plugins \
        --namespace "$namespace" \
        -o jsonpath='{.data.dynamic-plugins\.yaml}' \
        | sed -e 's/^/    /' -e 's/{{inherit}}/{{ "{{inherit}}" }}/g' \
        >> "$DYNAMIC_PLUGINS_FILE"
else
    sed -e 's/^/    /' -e 's/{{inherit}}/{{ "{{inherit}}" }}/g' \
        config/dynamic-plugins.yaml >> "$DYNAMIC_PLUGINS_FILE"
fi

# Build helm install arguments
HELM_ARGS=(
    -f "helm/value_file.yaml"
    -f "$DYNAMIC_PLUGINS_FILE"
    --set global.clusterRouterBase="${CLUSTER_ROUTER_BASE}"
    --set global.catalogIndex.image.registry="quay.io"
    --set global.catalogIndex.image.repository="rhdh/plugin-catalog-index"
    --set global.catalogIndex.image.tag="${CATALOG_INDEX_TAG}"
    --namespace "$namespace"
)

if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    HELM_ARGS+=(--set orchestrator.enabled=true)
    # setup-orchestrator.sh pre-installs Serverless/Logic + SonataFlowPlatform.
    # Keep orchestrator plugins enabled in RHDH, but prevent chart-managed
    # operator subscriptions from fighting the prepared OSL catalog.
    if [[ "${SKIP_ORCHESTRATOR_INFRA_INSTALL:-}" == "1" ]]; then
        HELM_ARGS+=(
            --set orchestrator.serverlessLogicOperator.enabled=false
            --set orchestrator.serverlessOperator.enabled=false
        )
    fi
fi

if [[ "${IS_AUTH_ENABLED:-false}" != "true" ]]; then
    HELM_ARGS+=(
        --set "upstream.backstage.extraAppConfig[1].configMapRef=app-config-guest-auth"
        --set "upstream.backstage.extraAppConfig[1].filename=app-config-guest-auth.yaml"
    )
elif [[ -n "${KEYCLOAK_BASE_URL:-}" ]]; then
    echo "Applying OIDC app-config from Keycloak at ${KEYCLOAK_BASE_URL}"
    oidc_tmp="$(mktemp)"
    cp config/app-config-oidc.yaml "$oidc_tmp"
    for key in KEYCLOAK_METADATA_URL KEYCLOAK_CLIENT_ID KEYCLOAK_CLIENT_SECRET RHDH_BASE_URL SONATAFLOW_DATA_INDEX_URL; do
        val="${!key:-}"
        val_esc="$(printf '%s' "$val" | sed -e 's/[&\\#]/\\&/g')"
        sed -i "s#\${${key}}#${val_esc}#g" "$oidc_tmp"
    done
    oc create configmap app-config-oidc \
        --from-file=app-config-oidc.yaml="$oidc_tmp" \
        --namespace "$namespace" --dry-run=client -o yaml \
        | oc apply -f - --namespace "$namespace" >/dev/null
    rm -f "$oidc_tmp"
    HELM_ARGS+=(
        --set "upstream.backstage.extraAppConfig[1].configMapRef=app-config-oidc"
        --set "upstream.backstage.extraAppConfig[1].filename=app-config-oidc.yaml"
    )
fi

# Install or upgrade Helm chart
helm upgrade --install redhat-developer-hub "${CHART_URL}" --version "$CV" "${HELM_ARGS[@]}"

# Scale down and up to ensure fresh pods (helm does not monitor config changes)
oc scale deployment -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub)' --replicas=0 -n "$namespace"
oc wait --for=delete pod -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub),app.kubernetes.io/name!=postgresql' -n "$namespace" --timeout=120s || true
oc scale deployment -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub)' --replicas=1 -n "$namespace"
