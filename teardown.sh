#!/usr/bin/env bash
set -e

# =============================================================================
# teardown.sh — Remove an RHDH test instance and its cluster resources
#
# Removes the RHDH deployment, namespace-scoped configuration (ConfigMaps,
# secrets, catalog entities), and the instance's OIDC client in the shared
# Keycloak. Shared infrastructure (Keycloak itself, the Operator) is kept unless
# explicitly requested.
#
# Usage:
#   ./teardown.sh <install-method> [--namespace <ns>] [--plugins <list>] [--clean]
#
# Options:
#   --namespace <ns>   Namespace to clean up (default: rhdh)
#   --plugins <list>   Also teardown plugin infrastructure (e.g. lighthouse,keycloak)
#   --clean            Delete the entire namespace after teardown
# =============================================================================

namespace="rhdh"
installation_method=""
# Plugin infrastructure to tear down. Only set from the command line: PLUGINS
# from .env (used to deploy an instance) must never trigger infrastructure
# teardown.
plugins_arg=""
CLEAN=false

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <install-method> [--namespace <ns>] [--plugins <list>] [--clean]"
    exit 1
fi

installation_method="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            namespace="$2"
            shift 2
            ;;
        --plugins)
            plugins_arg="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ "$installation_method" != "helm" && "$installation_method" != "operator" ]]; then
    echo "Error: Install method must be 'helm' or 'operator'"
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/scripts/deployment-common.sh"

[[ "${OPENSHIFT_CI}" != "true" && -f .env ]] && source .env

export NAMESPACE="$namespace"

echo ""
echo "=============================================="
echo "Tearing down RHDH (${installation_method}) in namespace: ${namespace}"
echo "=============================================="

# ---------------------------------------------------------------------------
# Step 1: Tear down explicitly requested plugin infrastructure while the
#         namespace still exists.
# ---------------------------------------------------------------------------
if [[ -n "${plugins_arg}" ]]; then
    echo ""
    echo "Tearing down plugin infrastructure: ${plugins_arg}"
    source scripts/config-plugins.sh
    TEARDOWN=true main "${plugins_arg}"
fi

# ---------------------------------------------------------------------------
# Step 2: Remove the RHDH deployment.
# ---------------------------------------------------------------------------
echo ""
echo "Removing RHDH deployment..."
if [[ "$installation_method" == "helm" ]]; then
    helm uninstall redhat-developer-hub -n "$namespace" || true
    # StatefulSet PVCs are not deleted by Helm uninstall.
    oc delete pvc data-redhat-developer-hub-postgresql-0 \
        -n "$namespace" --ignore-not-found
else
    oc delete backstage developer-hub -n "$namespace" --ignore-not-found
fi

# ---------------------------------------------------------------------------
# Step 3: Remove the per-instance OIDC client from the shared Keycloak.
#         Best effort: Keycloak may be gone already, or never have been used.
# ---------------------------------------------------------------------------
if command -v oc >/dev/null && oc get statefulset keycloak -n "${KEYCLOAK_NS:-rhdh-keycloak}" &>/dev/null; then
    source scripts/config-plugins.sh
    # Never wait for Keycloak during teardown.
    TIMEOUT=0 uninstall_keycloak || echo "Warning: Could not remove the Keycloak client — continuing."
fi

# ---------------------------------------------------------------------------
# Step 4: Remove namespace-scoped resources.
# ---------------------------------------------------------------------------
source scripts/setup-resources.sh
teardown_resources

echo ""
echo "=============================================="
echo "Teardown complete."
echo "=============================================="

if [[ "${CLEAN}" == "true" ]]; then
    echo ""
    echo "--clean specified: deleting namespace ${namespace}..."
    oc delete project "$namespace" --ignore-not-found
    echo "Namespace ${namespace} deleted."
fi
