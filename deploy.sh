#!/bin/bash
set -e

# Default values
namespace="rhdh"
installation_method=""
CV=""
github=0 # by default don't use the Github repo unless the chart doesn't exist in the OCI registry
WITH_ORCHESTRATOR=0

# Parse arguments
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <installation-method> <version> [--namespace <ns>] [--with-orchestrator]"
    echo "Installation methods: helm, operator"
    echo "Options:"
    echo "  --namespace <ns>       Deploy to specified namespace (default: rhdh)"
    echo "  --with-orchestrator    Deploy with orchestrator support"
    echo "Examples:"
    echo "  $0 helm 1.5-171-CI"
    echo "  $0 helm next"
    echo "  $0 operator 1.5"
    echo "  $0 helm 1.9 --with-orchestrator"
    echo "  $0 helm 1.9 --namespace rhdh-helm --with-orchestrator"
    exit 1
fi

installation_method="$1"
version="$2"
shift 2

# Parse optional flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            namespace="$2"
            shift 2
            ;;
        --with-orchestrator)
            WITH_ORCHESTRATOR=1
            echo "Orchestrator support enabled"
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 <installation-method> <version> [--namespace <ns>] [--with-orchestrator]"
            exit 1
            ;;
    esac
done

export WITH_ORCHESTRATOR

# Validate installation method
if [[ "$installation_method" != "helm" && "$installation_method" != "operator" ]]; then
    echo "Error: Installation method must be either 'helm' or 'operator'"
    echo "Usage: $0 <installation-method> <version>"
    [[ "$OPENSHIFT_CI" == "true" ]] && gh_comment "❌ **Error: Invalid installation method** 🚫\n\n📝 **Provided installation method:** \`$installation_method\`\n\nInstallation method must be either 'helm' or 'operator' 🔄"
    exit 1
fi

[[ "${OPENSHIFT_CI}" != "true" ]] && source .env
# source utils/utils.sh

# Deploy Keycloak with users and roles.
# comment this out if you don't want to deploy Keycloak or use your own Keycloak instance.
source utils/keycloak/keycloak-deploy.sh $namespace

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
    # In CI, auto-install the operator if not already present (CI has Linux tools available)
    # TODO(RHIDP-12127): move operator install and orchestrator support to CI step registry script
    if [[ "${OPENSHIFT_CI}" == "true" ]] && ! oc get crd/backstages.rhdh.redhat.com &>/dev/null; then
        echo "Operator not found, installing automatically (CI mode)..."
        source operator/install-operator.sh "$version"
    fi
    source operator/deploy.sh "$namespace" "$version"
fi

# Wait for the deployment to be ready
oc rollout status deployment -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub)' -n "$namespace" --timeout=500s || echo "Error: Timed out waiting for deployment to be ready."

echo "
RHDH_BASE_URL : 
$RHDH_BASE_URL
"