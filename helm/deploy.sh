#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# helm/deploy.sh — Install RHDH with the Helm chart
#
# Called by deploy.sh after the configuration ConfigMaps have been created.
# Set RHDH_RENDER_ONLY=true to render the manifests instead of installing them
# (used by scripts/verify-plugins.sh).
# =============================================================================

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <namespace> <version>" >&2
    exit 1
fi

namespace="$1"
version="$2"

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
parse_rhdh_version "$version"
resolve_plugins "${PLUGINS_RESOLVED:-${PLUGINS:-}}"

CV="${RESOLVED_HELM_CHART_VERSION:-$(resolve_helm_chart_version "$version")}"
if [[ -z "${CV}" ]]; then
    echo "Error: Could not resolve a Helm chart version for '${version}'." >&2
    echo "Check available tags: https://quay.io/repository/rhdh/chart?tab=tags" >&2
    exit 1
fi
echo "Using Helm chart version: ${CV}"

CHART_URL="oci://quay.io/rhdh/chart"
helm show chart "$CHART_URL" --version "$CV" >/dev/null

# ── Orchestrator infrastructure ───────────────────────────────────────────────
if plugin_enabled orchestrator && [[ "${RHDH_RENDER_ONLY:-false}" != "true" ]]; then
    if oc get pods -n openshift-serverless --no-headers 2>/dev/null | grep -q . && \
       oc get pods -n openshift-serverless-logic --no-headers 2>/dev/null | grep -q .; then
        echo "Serverless operators already running on cluster, skipping infra chart."
    else
        # Infra chart tags lag the main RHDH chart (e.g. chart 2.2-110-CI vs
        # infra 2.2-99-CI). Resolve an available tag on the same release line.
        chart_line=$(grep -oE '^[0-9]+\.[0-9]+' <<< "$CV")
        INFRA_CV=""
        if helm show chart oci://quay.io/rhdh/orchestrator-infra-chart --version "$CV" &>/dev/null; then
            INFRA_CV="$CV"
        else
            INFRA_CV=$(quay_latest_tag "rhdh/orchestrator-infra-chart" "$chart_line")
        fi
        if [[ -z "${INFRA_CV}" ]]; then
            echo "Error: No RHDH ${chart_line} orchestrator infrastructure chart is available." >&2
            exit 1
        fi
        if [[ "${INFRA_CV}" != "${CV}" ]]; then
            echo "Orchestrator infra chart '${CV}' not found; using '${INFRA_CV}' instead."
        fi

        INFRA_ARGS=(--version "$INFRA_CV" --namespace "$namespace"
            --wait --timeout=5m
            --set serverlessLogicOperator.subscription.spec.installPlanApproval=Automatic
            --set serverlessOperator.subscription.spec.installPlanApproval=Automatic)
        if helm show crds oci://quay.io/rhdh/orchestrator-infra-chart --version "$INFRA_CV" &>/dev/null; then
            if oc get crd knativeservings.operator.knative.dev &>/dev/null; then
                INFRA_ARGS+=(--skip-crds)
            fi
        fi
        helm upgrade --install orchestrator-infra oci://quay.io/rhdh/orchestrator-infra-chart "${INFRA_ARGS[@]}"
        echo "Orchestrator infrastructure chart installed successfully."
    fi

    echo "Waiting for the serverless APIs..."
    wait_for_crd sonataflowplatforms.sonataflow.org
    wait_for_crd knativeservings.operator.knative.dev
fi

# ── Chart values ──────────────────────────────────────────────────────────────
# Dynamic plugins come from the merged configuration built by deploy.sh (or the
# base file when this script is run standalone).
DYNAMIC_PLUGINS_FILE="${DYNAMIC_PLUGINS_FILE:-${DEPLOY_ROOT}/config/dynamic-plugins.yaml}"
DYNAMIC_PLUGINS_VALUES="${DEPLOY_WORKDIR:-$(mktemp -d)}/helm-dynamic-plugins.json"
yq -o=json '{"dynamicPlugins": .}' "$DYNAMIC_PLUGINS_FILE" > "$DYNAMIC_PLUGINS_VALUES"

EXTRA_APP_CONFIGS='[{"configMapRef":"app-config-rhdh","filename":"app-config-rhdh.yaml"}]'

HELM_ARGS=(
    -f "${DEPLOY_ROOT}/helm/value_file.yaml"
    -f "$DYNAMIC_PLUGINS_VALUES"
    --set "openshift.clusterRouterBase=${CLUSTER_ROUTER_BASE}"
    --set-json "extraAppConfig=${EXTRA_APP_CONFIGS}"
    --namespace "$namespace"
)

if [[ -n "${CATALOG_INDEX_IMAGE:-}" ]]; then
    HELM_ARGS+=(--set-json "catalogIndex.image=$(image_values "$CATALOG_INDEX_IMAGE")")
fi

# The chart appends its own plugin list when these components are enabled.
if plugin_enabled orchestrator; then
    HELM_ARGS+=(--set orchestrator.enabled=true)
fi
if plugin_enabled intelligent-assistant; then
    HELM_ARGS+=(--set intelligentAssistant.enabled=true)
    if [[ "${LIGHTSPEED_HAS_PROVIDER:-false}" == "true" ]]; then
        HELM_ARGS+=(
            --set intelligentAssistant.existingSecret=intelligent-assistant-secrets
            --set intelligentAssistant.config.stack.existingConfigMap.name=intelligent-assistant-stack
            --set intelligentAssistant.config.stack.existingConfigMap.key=lightspeed-stack.yaml
        )
    fi
else
    # The 2.2 chart enables Intelligent Assistant by default; only run the
    # sidecar when the plugin (and therefore a possible provider) is selected.
    HELM_ARGS+=(--set intelligentAssistant.enabled=false)
fi

if [[ -n "${RHDH_IMAGE:-}" ]]; then
    HELM_ARGS+=(--set-json "image=$(image_values "$RHDH_IMAGE")")
fi

if [[ "${RHDH_RENDER_ONLY:-false}" == "true" ]]; then
    helm template redhat-developer-hub "$CHART_URL" --version "$CV" "${HELM_ARGS[@]}"
    exit 0
fi

helm upgrade --install redhat-developer-hub "$CHART_URL" --version "$CV" "${HELM_ARGS[@]}"
