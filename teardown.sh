#!/bin/bash
set -e

# =============================================================================
# teardown.sh — Remove an RHDH test instance and associated cluster resources
#
# Tears down the RHDH deployment, shared cluster resources (catalog ConfigMaps,
# RBAC, image streams, demo workloads, rhdh-secrets), and optionally plugin
# infrastructure (Keycloak, Lighthouse).
#
# Usage:
#   ./teardown.sh <install-method> [--namespace <ns>] [--plugins <list>]
#
# Install methods: helm, operator
# Options:
#   --namespace <ns>     Namespace to clean up (default: rhdh)
#   --plugins <list>     Comma-separated plugins to also teardown (e.g. keycloak,lighthouse)
#
# Examples:
#   ./teardown.sh helm
#   ./teardown.sh helm --namespace rhdh-helm --plugins keycloak,lighthouse
#   ./teardown.sh operator --plugins keycloak
# =============================================================================

# Default values
namespace="rhdh"
installation_method=""
PLUGINS=""
CLEAN=false

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <install-method> [--namespace <ns>] [--plugins <list>] [--clean]"
    echo "Install methods: helm, operator"
    echo "Options:"
    echo "  --namespace <ns>     Namespace to clean up (default: rhdh)"
    echo "  --plugins <list>     Comma-separated plugin infra to teardown (e.g. keycloak,lighthouse)"
    echo "  --clean              Delete the entire namespace after teardown (full wipe)"
    echo "Examples:"
    echo "  $0 helm"
    echo "  $0 helm --namespace rhdh-helm --plugins keycloak,lighthouse"
    echo "  $0 operator --plugins keycloak"
    echo "  $0 helm --clean"
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
            PLUGINS="$2"
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

[[ "${OPENSHIFT_CI}" != "true" ]] && source .env

export NAMESPACE="$namespace"

echo ""
echo "=============================================="
echo "Tearing down RHDH (${installation_method}) in namespace: ${namespace}"
echo "=============================================="

# ---------------------------------------------------------------------------
# Step 1: Tear down plugin infrastructure (Keycloak, Lighthouse, etc.)
#         Do this first while the namespace still exists.
# ---------------------------------------------------------------------------
if [[ -n "${PLUGINS}" ]]; then
    echo ""
    echo "Tearing down plugin infrastructure: ${PLUGINS}"
    source scripts/config-plugins.sh
    TEARDOWN=true main "${PLUGINS}"
fi

# ---------------------------------------------------------------------------
# Step 2: Remove the RHDH deployment itself.
# ---------------------------------------------------------------------------
echo ""
echo "Removing RHDH deployment..."
if [[ "$installation_method" == "helm" ]]; then
    helm uninstall redhat-developer-hub -n "$namespace" || true
    # StatefulSet PVCs are not deleted by Helm uninstall — remove explicitly so
    # a subsequent deploy does not conflict with the leftover volume.
    oc delete pvc data-redhat-developer-hub-postgresql-0 \
        -n "$namespace" --ignore-not-found
else
    oc delete backstage developer-hub -n "$namespace" --ignore-not-found
fi

# ---------------------------------------------------------------------------
# Step 3: Tear down shared cluster resources (catalog ConfigMaps, RBAC,
#         image streams, demo resources, rhdh-secrets Secret).
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
