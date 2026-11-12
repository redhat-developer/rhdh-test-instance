#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# operator/deploy.sh — Deploy an RHDH instance with the Operator
#
# Assumes the Operator is already installed (make install-operator) or that CI
# has bootstrapped it. deploy.sh applies the configuration ConfigMaps first.
# =============================================================================

namespace="${1:?Usage: deploy.sh <namespace> <version>}"
version="${2:?Usage: deploy.sh <namespace> <version>}"

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
parse_rhdh_version "$version"
resolve_plugins "${PLUGINS_RESOLVED:-${PLUGINS:-}}"
resolve_catalog_image
prepare_deploy_workdir

# Never select an arbitrary served version or fall back to an older API.
if ! oc get crd backstages.rhdh.redhat.com -o json \
    | jq -e '.spec.versions[] | select(.name == "v1alpha5" and .served)' >/dev/null; then
    echo "Error: The Operator must serve rhdh.redhat.com/v1alpha5. Run make install-operator." >&2
    exit 1
fi

if plugin_enabled orchestrator; then
    echo "Installing Orchestrator infrastructure..."
    infra_branch=$(upstream_branch_for rhdh-operator)
    curl -fsSL "https://raw.githubusercontent.com/redhat-developer/rhdh-operator/${infra_branch}/config/profile/rhdh/plugin-infra/plugin-infra.sh" \
        -o "${DEPLOY_WORKDIR}/plugin-infra.sh"
    bash "${DEPLOY_WORKDIR}/plugin-infra.sh" apply --branch "${infra_branch}"
    wait_for_crd sonataflowplatforms.sonataflow.org
fi

export LIGHTSPEED_HAS_PROVIDER="${LIGHTSPEED_HAS_PROVIDER:-false}"
bash "${DEPLOY_ROOT}/operator/render-cr.sh" "$namespace" "$version" > "${DEPLOY_WORKDIR}/backstage.json"
oc apply --validate=strict -f "${DEPLOY_WORKDIR}/backstage.json" -n "$namespace"
oc wait --for=condition=Deployed backstage/developer-hub -n "$namespace" --timeout=600s
