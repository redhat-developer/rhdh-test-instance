#!/usr/bin/env bash
set -e

# =============================================================================
# deploy.sh — Deploy an RHDH test instance
#
# Usage:
#   ./deploy.sh <helm|operator> <version> [--namespace <ns>] [--plugins <list>]
#
# Versions: 2.2, 2.2.3, 2.2-120-CI, next
# Plugins:  see "Available plugins" below; "all" enables every optional plugin,
#           "-name" excludes one (e.g. "all,-orchestrator").
# =============================================================================

namespace="rhdh"
installation_method=""
plugins_arg=""

usage() {
    echo "Usage: $0 <installation-method> <version> [--namespace <ns>] [--plugins <list>]"
    echo "Installation methods: helm, operator"
    echo "Options:"
    echo "  --namespace <ns>    Deploy to the specified namespace (default: rhdh)"
    echo "  --plugins <list>    Comma-separated optional plugins, 'all', or 'all,-name'"
    echo "Available plugins: keycloak (always on), kubernetes, bulk-import,"
    echo "                   intelligent-assistant, orchestrator, scorecard, rbac, lighthouse"
    echo "Examples:"
    echo "  $0 helm 2.2"
    echo "  $0 helm next --plugins kubernetes,rbac"
    echo "  $0 operator 2.2 --namespace team-a --plugins all,-orchestrator"
}

ci_comment() {
    if [[ "${OPENSHIFT_CI}" == "true" ]] && declare -F gh_comment >/dev/null; then
        gh_comment "$1"
    fi
}

if [[ $# -lt 2 ]]; then
    usage
    exit 1
fi

installation_method="$1"
version="$2"
shift 2

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
        --with-orchestrator)
            echo "Warning: --with-orchestrator is deprecated; use --plugins orchestrator." >&2
            plugins_arg="${plugins_arg:+${plugins_arg},}orchestrator"
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$installation_method" != "helm" && "$installation_method" != "operator" ]]; then
    echo "Error: Installation method must be either 'helm' or 'operator'"
    ci_comment "❌ **Error: Invalid installation method** 🚫

📝 **Provided installation method:** \`${installation_method}\`

Installation method must be either 'helm' or 'operator' 🔄"
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/scripts/deployment-common.sh"

# Local deployments read secrets and optional settings from .env. CI injects
# them from GSM (OPENSHIFT_CI=true).
if [[ "${OPENSHIFT_CI}" != "true" && -f .env ]]; then
    source .env
fi

# The command line wins over PLUGINS from .env.
PLUGINS="${plugins_arg:-${PLUGINS:-}}"

if ! parse_rhdh_version "$version"; then
    ci_comment "❌ **Error: Invalid RHDH version** 🚫

📝 **Provided version:** \`${version}\`

Use \`2.2\`, a 2.2 patch release, a \`2.2-<build>-CI\` build, or \`next\`."
    exit 1
fi

for tool in oc jq yq; do
    command -v "$tool" >/dev/null || die "Required tool '${tool}' is not installed."
done
if [[ "$installation_method" == "helm" ]]; then
    command -v helm >/dev/null || die "Required tool 'helm' is not installed."
    # Resolve and validate the chart before anything is created on the cluster,
    # so a mistyped exact version fails fast and with a clear message.
    export RESOLVED_HELM_CHART_VERSION
    if ! RESOLVED_HELM_CHART_VERSION=$(resolve_helm_chart_version "$version") || \
        [[ -z "$RESOLVED_HELM_CHART_VERSION" ]]; then
        ci_comment "❌ **Error: No Helm chart for RHDH \`${version}\`** 🚫"
        die "No Helm chart is published for '${version}'. Check https://quay.io/repository/rhdh/chart?tab=tags"
    fi
    if ! validate_helm_chart_version "$version" "$RESOLVED_HELM_CHART_VERSION"; then
        ci_comment "❌ **Error: Helm chart \`${RESOLVED_HELM_CHART_VERSION}\` does not exist** 🚫"
        exit 1
    fi
fi

# Resolve CATALOG_INDEX_TAG into CATALOG_INDEX_IMAGE (and strip any oci://).
resolve_catalog_image

resolve_plugins "$PLUGINS" || {
    ci_comment "❌ **Error: Invalid plugin list** 🚫

📝 **Provided plugins:** \`${PLUGINS}\`

Use \`kubernetes\`, \`bulk-import\`, \`intelligent-assistant\`, \`orchestrator\`,
\`scorecard\`, \`rbac\`, \`lighthouse\`, \`all\` or \`all,-name\`."
    exit 1
}
prepare_deploy_workdir

echo "RHDH version: ${version}"
echo "Plugins: ${PLUGINS_RESOLVED}"

# Build the merged configuration once. The same files are used by the cluster
# ConfigMaps and, for Helm, by the chart values.
export APP_CONFIG_FILE="${DEPLOY_WORKDIR}/app-config-rhdh.yaml"
export DYNAMIC_PLUGINS_FILE="${DEPLOY_WORKDIR}/dynamic-plugins.yaml"
build_app_config "$APP_CONFIG_FILE"
build_dynamic_plugins "$DYNAMIC_PLUGINS_FILE"

# Create or switch to the specified namespace.
# The first label of the generated route host is
# backstage-developer-hub-<namespace>, which must stay within 63 characters.
if [[ ${#namespace} -gt 39 ]]; then
    die "Namespace '${namespace}' is too long (max 39 characters) for the generated route hostname."
fi
oc new-project "$namespace" || oc project "$namespace"

# Resolve cluster router base and RHDH URL early so setup-resources.sh and
# plugin scripts have them available.
export CLUSTER_ROUTER_BASE
CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')
if oc get route console -n openshift-console -o=jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
    RHDH_PROTOCOL="https"
else
    RHDH_PROTOCOL="http"
fi
if [[ "$installation_method" == "helm" ]]; then
    export RHDH_BASE_URL="${RHDH_PROTOCOL}://redhat-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"
else
    export RHDH_BASE_URL="${RHDH_PROTOCOL}://backstage-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"
fi
export NAMESPACE="$namespace"

echo "RHDH URL: ${RHDH_BASE_URL}"

source scripts/setup-resources.sh
setup_resources

# Keycloak and every optional plugin. Setup steps run round-robin so one
# plugin waiting for readiness does not block the others.
source scripts/config-plugins.sh
main "$PLUGINS_RESOLVED"

if [[ "$installation_method" == "helm" ]]; then
    bash helm/deploy.sh "$namespace" "$version"
else
    # In CI, bootstrap the shared Operator if it is not installed yet.
    if [[ "${OPENSHIFT_CI}" == "true" ]] && \
        ! oc get configmap rhdh-default-config -n "${OPERATOR_NAMESPACE:-rhdh-operator}" &>/dev/null; then
        echo "Operator not found, installing automatically (CI mode)..."
        bash operator/install-operator.sh "$version"
    fi
    bash operator/deploy.sh "$namespace" "$version"
fi

if [[ "$installation_method" == "helm" ]]; then
    deployment_name=redhat-developer-hub
else
    deployment_name=backstage-developer-hub
fi

if ! oc rollout status "deployment/${deployment_name}" -n "$namespace" --timeout=600s; then
    echo "Error: Timed out waiting for deployment/${deployment_name}." >&2
    echo "Recent dynamic plugin installation logs:" >&2
    oc logs "deployment/${deployment_name}" -c install-dynamic-plugins -n "$namespace" --tail=100 >&2 || true
    exit 1
fi

# In CI, verify the running instance with the smoke suite. A failure is reported
# in the PR but does not tear down the instance, so the cluster stays available
# for debugging.
if [[ "${OPENSHIFT_CI}" == "true" && "${SKIP_SMOKE:-false}" != "true" ]]; then
    echo "Running smoke checks against ${RHDH_BASE_URL}..."
    if RHDH_BASE_URL="$RHDH_BASE_URL" PLUGINS="$PLUGINS_RESOLVED" \
        ARTIFACT_DIR="${ARTIFACT_DIR:-}" bash scripts/run-smoke.sh; then
        ci_comment "✅ **Smoke checks passed**

🌐 ${RHDH_BASE_URL}

Plugins: \`${PLUGINS_RESOLVED}\`"
    else
        ci_comment "⚠️ **Smoke checks failed**

The deployment is up but the Playwright smoke suite failed. The instance stays
available for debugging; see the job artifacts for traces and screenshots.

🌐 ${RHDH_BASE_URL}

Plugins: \`${PLUGINS_RESOLVED}\`"
    fi
fi

echo "
RHDH_BASE_URL :
${RHDH_BASE_URL}
"
