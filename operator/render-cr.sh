#!/usr/bin/env bash
# Render the Backstage CR without cluster access, for review and validation.
# Usage: render-cr.sh <namespace> <version>
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
namespace="${1:?Usage: render-cr.sh <namespace> <version>}"
version="${2:?Usage: render-cr.sh <namespace> <version>}"
parse_rhdh_version "$version"
resolve_plugins "${PLUGINS_RESOLVED:-${PLUGINS:-}}"
resolve_catalog_image

orchestrator_enabled=false
intelligent_assistant_enabled=false
rbac_enabled=false
plugin_enabled orchestrator && orchestrator_enabled=true
plugin_enabled intelligent-assistant && intelligent_assistant_enabled=true
plugin_enabled rbac && rbac_enabled=true

yq -o=json '.' "${DEPLOY_ROOT}/operator/backstage.yaml" | jq \
    --arg namespace "$namespace" --arg url "${RHDH_BASE_URL:?RHDH_BASE_URL must be set}" \
    --arg catalog "${CATALOG_INDEX_IMAGE}" --arg image "${RHDH_IMAGE:-}" \
    --argjson orchestrator "$orchestrator_enabled" \
    --argjson intelligent_assistant "$intelligent_assistant_enabled" \
    --argjson rbac "$rbac_enabled" \
    --argjson provider "${LIGHTSPEED_HAS_PROVIDER:-false}" '
    .metadata.namespace = $namespace |
    .spec.application.extraEnvs.envs += [
        {name: "RHDH_BASE_URL", value: $url}
    ] |
    if $catalog != "" then
        .spec.application.extraEnvs.envs += [
            {name: "CATALOG_INDEX_IMAGE", value: $catalog, containers: ["install-dynamic-plugins"]}
        ]
    else . end |
    .spec.flavours = [
        {name: "intelligent-assistant", enabled: $intelligent_assistant},
        {name: "orchestrator", enabled: $orchestrator}
    ] |
    .spec.application.extraFiles = (
        (.spec.application.extraFiles // {}) |
        .configMaps = (
            (.configMaps // []) +
            (if $rbac then [{
                name: "rbac-policy",
                mountPath: "/opt/app-root/src/rbac"
            }] else [] end) +
            (if $intelligent_assistant and $provider then [{
                name: "intelligent-assistant-stack",
                key: "lightspeed-stack.yaml",
                mountPath: "/app-root",
                containers: ["lightspeed-core"]
            }] else [] end)
        )
    ) |
    if $intelligent_assistant and $provider then
        .spec.application.extraEnvs.secrets += [{name: "intelligent-assistant-secrets", containers: ["lightspeed-core"]}]
    else . end |
    if $image != "" then
        .spec.deployment.patch.spec.template.spec.containers[0].image = $image |
        .spec.deployment.patch.spec.template.spec.initContainers = [{
            name: "install-dynamic-plugins", image: $image
        }]
    else . end
'
