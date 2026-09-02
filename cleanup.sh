#!/bin/bash
#
# Thoroughly remove all RHDH, orchestrator, and OSL artifacts from the cluster
# so that a fresh deploy succeeds cleanly.
#
# Usage:
#   ./cleanup.sh [--namespace <ns>] [--include-operators] [--delete-namespace]
#
# Options:
#   --namespace <ns>      Target namespace (default: rhdh)
#   --include-operators   Also remove OSL/Serverless operators (logic-operator
#                         and serverless-operator only; other CSVs in
#                         openshift-operators are left in place)
#   --delete-namespace    Delete the target namespace itself at the end
#                         (required before leftover namespaces like rhdh fail verify)
#
# All commands are idempotent -- safe to run multiple times.

set -euo pipefail

namespace="rhdh"
include_operators=false
delete_namespace=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            namespace="$2"
            shift 2
            ;;
        --include-operators)
            include_operators=true
            shift
            ;;
        --delete-namespace)
            delete_namespace=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 [--namespace <ns>] [--include-operators] [--delete-namespace]"
            exit 1
            ;;
    esac
done

# Verify cluster connectivity
if ! oc whoami &>/dev/null; then
    echo "Error: Cannot connect to OpenShift cluster. Is CRC running and are you logged in?"
    echo "  Try: crc start && oc login -u kubeadmin https://api.crc.testing:6443"
    exit 1
fi

# Validate namespace
if [[ ! "$namespace" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "Error: Invalid namespace name: '$namespace' (must be lowercase alphanumeric/hyphens, 1-63 chars)"
    exit 1
fi

echo "==========================================="
echo "  RHDH / Orchestrator Cleanup"
echo "==========================================="
echo "Namespace:         $namespace"
echo "Include operators: $include_operators"
echo "Delete namespace:  $delete_namespace"
echo ""

# ---------------------------------------------------------------------------
# Helper: clean RHDH/orchestrator resources from a given namespace
# ---------------------------------------------------------------------------
clean_namespace() {
    local ns="$1"
    if ! oc get namespace "$ns" &>/dev/null; then
        return 0
    fi

    echo "--- Cleaning namespace: $ns ---"

    # SonataFlow resources (must go before Helm uninstall to avoid operator reconciliation fights)
    oc delete sonataflow --all -n "$ns" --ignore-not-found 2>/dev/null || true
    oc delete sonataflowplatform --all -n "$ns" --ignore-not-found 2>/dev/null || true

    # Helm releases
    helm uninstall redhat-developer-hub -n "$ns" 2>/dev/null || true
    helm uninstall keycloak -n "$ns" 2>/dev/null || true
    helm uninstall orchestrator-infra -n "$ns" 2>/dev/null || true
    helm uninstall orch-infra -n "$ns" 2>/dev/null || true

    # Keycloak Route (created manually, not Helm-managed)
    oc delete route keycloak -n "$ns" --ignore-not-found 2>/dev/null || true

    # Stale Jobs, ConfigMaps, Secrets
    oc delete jobs --all -n "$ns" --ignore-not-found 2>/dev/null || true
    oc delete configmap app-config-rhdh dynamic-plugins -n "$ns" --ignore-not-found 2>/dev/null || true
    oc delete secret rhdh-secrets backstage-psql-secret -n "$ns" --ignore-not-found 2>/dev/null || true
    oc delete service sample-server-service -n "$ns" --ignore-not-found 2>/dev/null || true

    # Workflow-related ConfigMaps
    for cm in greeting-props greeting-managed-props 01-greeting-resources-schemas \
               failswitch-props failswitch-managed-props 01-failswitch-resources-schemas 02-failswitch-resources-specs \
               token-propagation-props token-propagation-managed-props \
               01-token-propagation-resources-schemas 02-token-propagation-resources-specs; do
        oc delete configmap "$cm" -n "$ns" --ignore-not-found 2>/dev/null || true
    done

    # Remaining workloads: operator-created StatefulSets/Deployments survive Helm uninstall
    oc delete statefulset --all -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    oc delete deployment --all -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true

    # Force-delete all remaining pods (they block PVC deletion via pvc-protection finalizer)
    oc delete pods --all -n "$ns" --force --grace-period=0 2>/dev/null || true

    # PVCs (contain stale DB migrations/data; --wait=false prevents hanging on finalizers)
    oc delete pvc --all -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
}

delete_knative_webhooks() {
    echo "--- Removing stale Knative admission webhooks ---"
    oc delete validatingwebhookconfiguration \
        config.webhook.eventing.knative.dev \
        config.webhook.serving.knative.dev \
        validation.inmemorychannel.eventing.knative.dev \
        validation.webhook.eventing.knative.dev \
        validation.webhook.serving.knative.dev \
        --ignore-not-found 2>/dev/null || true
    oc delete mutatingwebhookconfiguration \
        inmemorychannel.eventing.knative.dev \
        sinkbindings.webhook.sources.knative.dev \
        webhook.eventing.knative.dev \
        webhook.serving.knative.dev \
        --ignore-not-found 2>/dev/null || true
}

OSL_OLM_MATCH='logic-operator|serverless-operator'

delete_osl_olm_resources() {
    local kind="$1"
    local ns="$2"
    local resource name

    for resource in $(oc get "$kind" -n "$ns" -o name 2>/dev/null); do
        name="${resource##*/}"
        if [[ "$name" =~ $OSL_OLM_MATCH ]]; then
            echo "  Deleting $resource in $ns"
            oc delete "$resource" -n "$ns" --ignore-not-found 2>/dev/null || true
        fi
    done
}

force_finalize_namespace_if_stuck() {
    local ns="$1"
    if ! oc get namespace "$ns" &>/dev/null; then
        return 0
    fi

    local phase
    phase="$(oc get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" != "Terminating" ]]; then
        return 0
    fi

    echo "  Namespace ${ns} is still Terminating; forcing finalization..."
    oc get namespace "$ns" -o json 2>/dev/null | \
        jq '.spec.finalizers=[]' | \
        oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
}

wait_for_namespace_gone() {
    local ns="$1"
    local timeout_secs="${2:-120}"
    local start
    start="$(date +%s)"

    while oc get namespace "$ns" &>/dev/null; do
        local elapsed=$(( $(date +%s) - start ))
        if [[ $elapsed -ge $timeout_secs ]]; then
            force_finalize_namespace_if_stuck "$ns"
            break
        fi
        sleep 3
    done
}

post_cleanup_verify() {
    local failures=0
    local ns remaining_subs remaining_csvs knative_webhooks

    echo "--- Post-clean verification ---"

    if [[ "$include_operators" == "true" ]]; then
        for ns in knative-serving knative-eventing knative-serving-ingress \
                  openshift-serverless openshift-serverless-logic orchestrator-infra \
                  orchestrator orchestrator-e2e rhdh-keycloak osl-mirror; do
            if oc get namespace "$ns" &>/dev/null; then
                echo "  Remaining namespace: $ns"
                failures=1
            fi
        done

        remaining_subs="$(oc get subscriptions.operators.coreos.com -A -o name 2>/dev/null | awk 'tolower($0) ~ /logic-operator|serverless-operator/' || true)"
        if [[ -n "$remaining_subs" ]]; then
            echo "  Remaining subscriptions:"
            echo "$remaining_subs" | sed 's/^/    /'
            failures=1
        fi

        remaining_csvs="$(oc get csv -A -o name 2>/dev/null | awk 'tolower($0) ~ /logic-operator|serverless-operator/' || true)"
        if [[ -n "$remaining_csvs" ]]; then
            echo "  Remaining CSVs:"
            echo "$remaining_csvs" | sed 's/^/    /'
            failures=1
        fi

        if oc get catalogsource osl-custom-catalog -n openshift-marketplace &>/dev/null; then
            echo "  Remaining catalogsource: openshift-marketplace/osl-custom-catalog"
            failures=1
        fi
        if oc get imagedigestmirrorset osl-bundle-mirror &>/dev/null; then
            echo "  Remaining IDMS: osl-bundle-mirror"
            failures=1
        fi

        knative_webhooks="$(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | awk 'tolower($0) ~ /knative/' || true)"
        if [[ -n "$knative_webhooks" ]]; then
            echo "  Remaining Knative webhooks:"
            echo "$knative_webhooks" | sed 's/^/    /'
            failures=1
        fi
    fi

    if [[ "$delete_namespace" == "true" ]] && oc get namespace "$namespace" &>/dev/null; then
        echo "  Remaining target namespace: $namespace"
        failures=1
    fi

    if [[ $failures -ne 0 ]]; then
        echo ""
        echo "Cleanup finished with residual resources. Re-run cleanup or inspect items above."
        exit 1
    fi

    echo "  Verification passed: no known leftovers for this cleanup mode."
}

# ---------------------------------------------------------------------------
# 1. Clean the target namespace
# ---------------------------------------------------------------------------
clean_namespace "$namespace"

# Also try orchestrator-infra in its own namespace
helm uninstall orchestrator-infra -n orchestrator-infra 2>/dev/null || true
helm uninstall orch-infra -n orchestrator-infra 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Clean namespaces created by orchestrator e2e tests
#    (rhdh-plugin-export-overlays/workspaces/orchestrator/e2e-tests)
#    Tests deploy into "orchestrator-app-next" (NFS) or older "orchestrator" /
#    "orchestrator-e2e" namespaces, and Keycloak into "rhdh-keycloak".
# ---------------------------------------------------------------------------
if [[ "$namespace" != "orchestrator-app-next" ]]; then
    clean_namespace "orchestrator-app-next"
fi
if [[ "$namespace" != "orchestrator" ]]; then
    clean_namespace "orchestrator"
fi
if [[ "$namespace" != "orchestrator-e2e" ]]; then
    clean_namespace "orchestrator-e2e"
fi
if [[ "$namespace" != "rhdh-keycloak" ]]; then
    clean_namespace "rhdh-keycloak"
fi

# ---------------------------------------------------------------------------
# 3. Cluster-scoped: operators and related resources
# ---------------------------------------------------------------------------
if [[ "$include_operators" == "true" ]]; then
    echo "--- Removing cluster-scoped operator resources ---"

    # Custom CatalogSource
    oc delete catalogsource osl-custom-catalog -n openshift-marketplace --ignore-not-found 2>/dev/null || true

    for ns in openshift-serverless-logic openshift-serverless openshift-operators; do
        delete_osl_olm_resources subscriptions.operators.coreos.com "$ns"
        delete_osl_olm_resources csv "$ns"
    done

    # ImageDigestMirrorSet
    oc delete imagedigestmirrorset osl-bundle-mirror --ignore-not-found 2>/dev/null || true

    # HelmChartRepository created for CI chart fallback builds
    oc delete helmchartrepository rhdh-next-ci-repo --ignore-not-found 2>/dev/null || true

    # Knative instances (must be deleted before their namespaces, or finalizers hang)
    echo "--- Removing Knative instances ---"
    oc delete knativeserving knative-serving -n knative-serving --ignore-not-found --timeout=60s 2>/dev/null || true
    oc delete knativeeventing knative-eventing -n knative-eventing --ignore-not-found --timeout=60s 2>/dev/null || true
    delete_knative_webhooks

    # All related namespaces (operator-created + alternative deployment patterns)
    echo "--- Removing operator and related namespaces ---"
    for ns in knative-serving knative-eventing knative-serving-ingress \
              openshift-serverless openshift-serverless-logic orchestrator-infra \
              orchestrator orchestrator-e2e rhdh-keycloak osl-mirror; do
        oc delete project "$ns" --ignore-not-found --timeout=60s 2>/dev/null || true
        wait_for_namespace_gone "$ns" 120
    done
fi

# ---------------------------------------------------------------------------
# 4. Optionally delete the target namespace
# ---------------------------------------------------------------------------
if [[ "$delete_namespace" == "true" ]]; then
    echo "--- Deleting namespace $namespace ---"
    oc delete project "$namespace" --ignore-not-found 2>/dev/null || true
    wait_for_namespace_gone "$namespace" 120
fi

post_cleanup_verify

echo ""
echo "==========================================="
echo "  Cleanup complete"
echo "==========================================="
