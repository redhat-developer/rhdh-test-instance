#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# operator/install-operator.sh — Install a published RHDH Operator through OLM
#
# Uses the upstream install-rhdh-catalog-source.sh from the matching release
# branch, which mirrors pre-release bundle images into the cluster registry.
# Requires oc, jq, yq, skopeo, umoci and opm: run it through
# `make install-operator` (containerized) unless those tools are installed.
#
# Usage: install-operator.sh [version]   (default: the newest supported line)
# =============================================================================

version="${1:-${VERSION:-}}"
if [[ -z "$version" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
parse_rhdh_version "$version"

# The operator branch tracks the release line, and the upstream installer only
# publishes per-line streams (quay.io/rhdh/iib:X.Y-<ocp>-<arch>), so an exact
# patch release or CI build cannot be installed this way.
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$version" =~ ^[0-9]+\.[0-9]+-[0-9]+-CI$ ]]; then
    echo "Warning: '${version}' cannot be pinned through the Operator installer; installing the newest ${RHDH_RELEASE_LINE} build." >&2
fi
if [[ "$version" == "next" ]]; then
    version_arg="--next"
else
    version_arg="-v ${RHDH_RELEASE_LINE}"
fi

branch=$(upstream_branch_for rhdh-operator)
echo "Using operator branch: ${branch}, version argument: ${version_arg}"

# The upstream OLM v1 installer creates the operator in rhdh-operator (with
# rhdh-default-config); OLM v0 installs a CSV instead. Check for either so a
# second run skips, and so the check does not depend on the OLM generation.
if oc get configmap rhdh-default-config -n "${OPERATOR_NAMESPACE:-rhdh-operator}" &>/dev/null || \
    oc get csv --all-namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q rhdh-operator; then
    echo "RHDH operator is already installed. Skipping."
    exit 0
fi

# Workaround for pushing to ARO cluster registries: https://access.redhat.com/solutions/6022011
# TODO: remove when install-rhdh-catalog-source.sh handles this itself.
oc patch configs.imageregistry.operator.openshift.io/cluster \
    --patch '{"spec":{"disableRedirect":true}}' --type=merge

installer="${DEPLOY_WORKDIR:-$(mktemp -d)}/install-rhdh-catalog-source.sh"
curl -fsSL "https://raw.githubusercontent.com/redhat-developer/rhdh-operator/${branch}/.rhdh/scripts/install-rhdh-catalog-source.sh" \
    -o "$installer"
chmod +x "$installer"

# Fix the hardcoded 'kubeadmin' username — on ARO clusters the admin user is
# 'kube:admin' and the colon breaks HTTP Basic Auth in skopeo. The internal
# registry validates the OAuth token, not the username.
if [[ "$(oc whoami)" != "kubeadmin" ]]; then
    echo "Patching install script for non-kubeadmin cluster (user: $(oc whoami))..."
    sed -i.bak \
        -e 's/skopeo login -u kubeadmin/skopeo login -u openshift/g' \
        -e 's/--docker-username=kubeadmin/--docker-username=openshift/g' \
        "$installer"
    rm -f "${installer}.bak"
fi

"$installer" ${version_arg} --install-operator rhdh

# Wait for the CRD to be available.
timeout 300 bash -c '
while ! oc get crd/backstages.rhdh.redhat.com >/dev/null 2>&1; do
    echo "Waiting for Backstage CRD to be created..."
    sleep 20
done
echo "Backstage CRD is created."
' || {
    echo "Error: Timed out waiting for the Backstage CRD." >&2
    exit 1
}

echo "RHDH operator installed successfully."
