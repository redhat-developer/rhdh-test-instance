#!/usr/bin/env bash

# =============================================================================
# deployment-common.sh — Shared helpers for deploy, teardown and verification
#
# Sourced by deploy.sh, helm/deploy.sh, operator/*.sh, teardown.sh and
# scripts/verify-plugins.sh. It resolves RHDH versions, catalog images and the
# optional plugin list, and builds the merged configuration files that are
# applied to the cluster.
# =============================================================================

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Release lines this repository can deploy. "next" always tracks the newest CI
# stream, so a new line only needs to be added here once it is supported.
SUPPORTED_RELEASE_LINES="${SUPPORTED_RELEASE_LINES:-2.2}"

# Shared Keycloak namespace. Also used by the catalog entities so the Keycloak
# entity points at the right namespace.
export KEYCLOAK_NS="${KEYCLOAK_NS:-rhdh-keycloak}"

die() {
    echo "Error: $*" >&2
    exit 1
}

prepare_deploy_workdir() {
    if [[ -z "${DEPLOY_WORKDIR:-}" ]]; then
        DEPLOY_WORKDIR=$(mktemp -d "${TMPDIR:-${PWD}}/rhdh-deploy.XXXXXX")
        trap 'rm -rf "${DEPLOY_WORKDIR}"' EXIT
    fi
    mkdir -p "${DEPLOY_WORKDIR}"
    export DEPLOY_WORKDIR
}

# =============================================================================
# Version resolution
#
# Accepted versions: "2.2" (latest chart on the line), "2.2.3" (patch release),
# "2.2-120-CI" (CI build) and "next" (newest CI build of any line).
# =============================================================================

# parse_rhdh_version <version>
# Exports RHDH_VERSION, RHDH_RELEASE_LINE (empty for next) and
# RHDH_UPSTREAM_BRANCH_USED_LATER (resolved per repository on demand).
parse_rhdh_version() {
    local version="$1"
    if [[ "$version" == "next" ]]; then
        export RHDH_VERSION="next"
        export RHDH_RELEASE_LINE=""
        return 0
    fi
    if [[ ! "$version" =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?(-[0-9]+-CI)?$ ]]; then
        echo "Error: Unsupported RHDH version '${version}'. Use '${SUPPORTED_RELEASE_LINES}', a patch release, a '<line>-<build>-CI' build, or 'next'." >&2
        return 1
    fi
    local line="${BASH_REMATCH[1]}"
    if ! grep -qx "$line" <<< "${SUPPORTED_RELEASE_LINES// /$'\n'}"; then
        echo "Error: Unsupported RHDH release line '${line}'. Supported lines: ${SUPPORTED_RELEASE_LINES}, or 'next'." >&2
        return 1
    fi
    export RHDH_VERSION="$version"
    export RHDH_RELEASE_LINE="$line"
}

# upstream_branch_for <repository> — release-X.Y when it exists, main otherwise.
# "next" always uses main.
upstream_branch_for() {
    local repository="$1"
    if [[ -z "${RHDH_RELEASE_LINE:-}" ]]; then
        echo "main"
        return 0
    fi
    if git ls-remote --exit-code --heads "https://github.com/redhat-developer/${repository}" \
        "release-${RHDH_RELEASE_LINE}" >/dev/null 2>&1; then
        echo "release-${RHDH_RELEASE_LINE}"
    else
        echo "main"
    fi
}

wait_for_crd() {
    local name="$1" deadline=$((SECONDS + 300))
    until oc get "crd/${name}" >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            echo "Error: Timed out waiting for CRD ${name}." >&2
            return 1
        fi
        sleep 5
    done
    oc wait --for=condition=Established "crd/${name}" --timeout=300s
}

# =============================================================================
# Catalog image resolution
# =============================================================================

# Apply explicit overrides only. When neither is set, the chart or Operator
# bundled catalog is used.
resolve_catalog_image() {
    export CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-}"
    export CATALOG_INDEX_IMAGE="${CATALOG_INDEX_IMAGE:-}"
    if [[ -z "$CATALOG_INDEX_IMAGE" && -n "$CATALOG_INDEX_TAG" ]]; then
        CATALOG_INDEX_IMAGE="quay.io/rhdh/plugin-catalog-index:${CATALOG_INDEX_TAG}"
    fi
    CATALOG_INDEX_IMAGE="${CATALOG_INDEX_IMAGE#oci://}"
    export CATALOG_INDEX_IMAGE
}

# Resolve the catalog image that the selected release would use anyway. This is
# only needed for verification; a CATALOG_INDEX_IMAGE override always wins.
resolve_deployment_catalog_image() {
    local method="$1" version="$2"
    resolve_catalog_image
    RESOLVED_CATALOG_INDEX_IMAGE="$CATALOG_INDEX_IMAGE"
    if [[ "$method" == "helm" ]]; then
        export RESOLVED_HELM_CHART_VERSION
        RESOLVED_HELM_CHART_VERSION=$(resolve_helm_chart_version "$version") || return 1
        if [[ -z "$RESOLVED_CATALOG_INDEX_IMAGE" ]]; then
            RESOLVED_CATALOG_INDEX_IMAGE=$(helm show values oci://quay.io/rhdh/chart \
                --version "$RESOLVED_HELM_CHART_VERSION" | yq -o=json '.' | jq -er '
                .catalogIndex.image | .registry + "/" + .repository +
                (if (.digest // "") != "" then "@" + .digest else ":" + .tag end)') || return 1
        fi
    elif [[ -z "$RESOLVED_CATALOG_INDEX_IMAGE" ]]; then
        RESOLVED_CATALOG_INDEX_IMAGE=$(oc get configmap rhdh-default-config \
            -n "${OPERATOR_NAMESPACE:-rhdh-operator}" -o json \
            | jq -er '.data["deployment.yaml"]' | yq -o=json '.' | jq -er '
            .spec.template.spec.initContainers[] | select(.name == "install-dynamic-plugins") |
            .env[] | select(.name == "CATALOG_INDEX_IMAGE") | .value') || {
            echo "Error: Cannot read the Operator's bundled catalog. Run make install-operator first." >&2
            return 1
        }
    fi
    [[ -n "$RESOLVED_CATALOG_INDEX_IMAGE" ]] || return 1
    export RESOLVED_CATALOG_INDEX_IMAGE
    echo "Using plugin catalog: ${RESOLVED_CATALOG_INDEX_IMAGE}" >&2
}

# =============================================================================
# Image values
# =============================================================================

# Translate a full image reference into the chart's image values, including
# registry ports and digest overrides.
image_values() {
    local image="$1" name tag="" digest=""
    if [[ "$image" != */* ]]; then
        echo "Error: Use a full registry/repository image reference: $image" >&2
        return 1
    fi
    name="${image%@*}"
    if [[ "$image" == *@* ]]; then
        digest="${image##*@}"
        if [[ "${name##*/}" == *:* ]]; then name="${name%:*}"; fi
    elif [[ "${name##*/}" == *:* ]]; then
        tag="${name##*:}"
        name="${name%:*}"
    else
        tag="latest"
    fi
    jq -n --arg registry "${name%%/*}" --arg repository "${name#*/}" \
        --arg tag "$tag" --arg digest "$digest" \
        '{registry: $registry, repository: $repository, tag: $tag, digest: $digest}'
}

# =============================================================================
# Helm chart tags on Quay
# =============================================================================

_quay_tags() {
    local repo="$1" prefix="$2" page=1 response
    while true; do
        response=$(curl -fsSG "https://quay.io/api/v1/repository/${repo}/tag/" \
            --data-urlencode "onlyActiveTags=true" --data-urlencode "limit=100" \
            --data-urlencode "page=${page}" --data-urlencode "filter_tag_name=like:${prefix}") || return 1
        jq -r '.tags[]?.name // empty' <<< "$response"
        [[ "$(jq -r '.has_additional // false' <<< "$response")" == "true" ]] || break
        page=$((page + 1))
    done
}

# Newest tag on a release line: either a GA patch (X.Y.Z) or a CI build (X.Y-N-CI).
quay_latest_tag() {
    local repo="$1" line="$2"
    _quay_tags "$repo" "$line" \
        | grep -E "^${line}(-[0-9]+-CI|\.[0-9]+)*$" \
        | sort -V | tail -n 1
}

# Newest CI build across all release lines, used for "next".
quay_latest_ci_tag() {
    local repo="$1"
    _quay_tags "$repo" "" \
        | grep -E "^[0-9]+\.[0-9]+-[0-9]+-CI$" \
        | sort -V | tail -n 1
}

# resolve_helm_chart_version <version> — prints the chart tag to install.
# An explicit patch release (X.Y.Z) or CI build (X.Y-N-CI) is used as given;
# "X.Y" and "next" resolve to the newest tag on their stream.
resolve_helm_chart_version() {
    local version="$1" line
    if [[ "$version" == "next" ]]; then
        quay_latest_ci_tag "rhdh/chart"
        return
    fi
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$version" =~ ^[0-9]+\.[0-9]+-[0-9]+-CI$ ]]; then
        # Existence is checked by the caller (helm show chart).
        echo "$version"
        return
    fi
    line=$(grep -oE '^[0-9]+\.[0-9]+' <<< "$version") || return 1
    quay_latest_tag "rhdh/chart" "$line"
}

# fetch_chart <version> <destination> — pull and untar the chart so files
# bundled with the selected release can be reused (Intelligent Assistant stack).
fetch_chart() {
    local version="$1" destination="$2" chart_version
    [[ -f "${destination}/chart/Chart.yaml" ]] && return 0
    chart_version=$(resolve_helm_chart_version "$version")
    [[ -n "$chart_version" ]] || return 1
    mkdir -p "$destination"
    helm pull oci://quay.io/rhdh/chart --version "$chart_version" \
        --untar --untardir "$destination" >/dev/null || return 1
    [[ -d "${destination}/rhdh" ]] && mv "${destination}/rhdh" "${destination}/chart"
    [[ -f "${destination}/chart/Chart.yaml" ]]
}

# =============================================================================
# Plugin selection
#
# Every optional feature is a plugin: resources/<name>/dynamic-plugins.yaml,
# optionally resources/<name>/app-config.yaml, and setup/teardown functions
# registered in scripts/config-plugins.sh.
# =============================================================================

# Order defines the order in which plugin configuration is merged.
PLUGIN_NAMES=(keycloak kubernetes bulk-import intelligent-assistant orchestrator scorecard rbac lighthouse)
ALWAYS_ON_PLUGINS=(keycloak)

# resolve_plugins <comma-separated list> [--explicit-only]
# Supports "all" and "-name" exclusions, e.g. "all,-orchestrator". Keycloak is
# always included because OIDC authentication is part of every deployment.
# --explicit-only is used by teardown: only plugins that are named explicitly
# are selected, so "all" never tears down an always-on plugin such as the
# shared Keycloak.
resolve_plugins() {
    local spec="${1:-}" explicit_only=false token name
    [[ "${2:-}" == "--explicit-only" ]] && explicit_only=true
    local -A selected=()
    local -a add=() remove=() tokens

    IFS=',' read -ra tokens <<< "$spec"
    for token in "${tokens[@]}"; do
        token="${token//[[:space:]]/}"
        [[ -z "$token" ]] && continue
        if [[ "$token" == "all" ]]; then
            for name in "${PLUGIN_NAMES[@]}"; do
                # Always-on plugins are shared infrastructure: "all" must not
                # include them when only explicitly named plugins are selected.
                [[ "$explicit_only" == "true" && " ${ALWAYS_ON_PLUGINS[*]} " == *" ${name} "* ]] && continue
                add+=("$name")
            done
        elif [[ "$token" == -* ]]; then
            remove+=("${token#-}")
        else
            add+=("${token}")
        fi
    done

    for name in "${add[@]}"; do
        if [[ " ${PLUGIN_NAMES[*]} " != *" ${name} "* ]]; then
            echo "Error: Unknown plugin '${name}'. Available plugins: ${PLUGIN_NAMES[*]}." >&2
            return 1
        fi
        selected["$name"]=1
    done
    for name in "${remove[@]}"; do
        if [[ " ${PLUGIN_NAMES[*]} " != *" ${name} "* ]]; then
            echo "Error: Unknown plugin '${name}' in the exclusion list. Available plugins: ${PLUGIN_NAMES[*]}." >&2
            return 1
        fi
        unset "selected[${name}]"
    done
    if [[ "$explicit_only" == "false" ]]; then
        for name in "${ALWAYS_ON_PLUGINS[@]}"; do
            selected["$name"]=1
        done
    fi

    PLUGIN_LIST=()
    for name in "${PLUGIN_NAMES[@]}"; do
        [[ -n "${selected[$name]:-}" ]] && PLUGIN_LIST+=("$name")
    done
    PLUGINS_RESOLVED=$(IFS=,; printf '%s' "${PLUGIN_LIST[*]}")
    export PLUGINS_RESOLVED
}

plugin_enabled() {
    [[ -n "${PLUGIN_LIST+x}" ]] || resolve_plugins "${PLUGINS_RESOLVED:-${PLUGINS:-}}"
    local name
    for name in "${PLUGIN_LIST[@]}"; do
        [[ "$name" == "$1" ]] && return 0
    done
    return 1
}

# Files contributed by the selected plugins.
plugin_dynamic_config_files() {
    local name file
    for name in "${PLUGIN_LIST[@]}"; do
        file="${DEPLOY_ROOT}/resources/${name}/dynamic-plugins.yaml"
        [[ -f "$file" ]] && echo "$file"
    done
}

plugin_app_config_files() {
    local name file
    for name in "${PLUGIN_LIST[@]}"; do
        file="${DEPLOY_ROOT}/resources/${name}/app-config.yaml"
        [[ -f "$file" ]] && echo "$file"
    done
}

# build_dynamic_plugins <output> — dynamic-plugins.yaml with all selected
# plugin entries. Starts from config/dynamic-plugins.yaml (includes + plugins)
# and appends each selected plugin's resources/<name>/dynamic-plugins.yaml,
# which must be a document with a plugins: list (same layout as the plugin
# catalog and the Operator flavours). Component plugins provided by the Helm
# chart or Operator flavours (orchestrator, intelligent-assistant) contribute
# no entries here.
build_dynamic_plugins() {
    local output="$1" file
    local merged="${DEPLOY_WORKDIR:-$(dirname "$output")}/plugins.json"
    local base="${DEPLOY_ROOT}/config/dynamic-plugins.yaml"

    yq -o=json '.' "$base" \
        | jq '{includes: (.includes // ["dynamic-plugins.default.yaml"]), plugins: (.plugins // [])}' > "$merged"

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if [[ "$(yq '.plugins | tag' "$file" 2>/dev/null)" != "!!seq" ]]; then
            die "${file} must be a dynamic-plugins document with a 'plugins:' list."
        fi
        yq -o=json '.plugins' "$file" > "${merged}.new"
        jq -s '.[1] as $new | .[0] | .plugins += $new' "$merged" "${merged}.new" > "${merged}.tmp"
        mv "${merged}.tmp" "$merged"
        rm -f "${merged}.new"
    done < <(plugin_dynamic_config_files)

    yq -p=json -o=yaml '.' "$merged" > "$output"
}

# build_app_config <output> — app-config-rhdh.yaml merged from the base config
# and every selected plugin. Maps are merged recursively; arrays are replaced,
# matching Backstage's own config layering.
build_app_config() {
    local output="$1" file args=("${DEPLOY_ROOT}/config/app-config-rhdh.yaml")
    while IFS= read -r file; do
        [[ -n "$file" ]] && args+=("$file")
    done < <(plugin_app_config_files)

    yq eval-all '. as $item ireduce ({}; . * $item)' "${args[@]}" > "$output"

    # A GitHub token is optional. Reference it without inlining the value: the
    # Secret is already injected into the pod as GITHUB_TOKEN, and writing the
    # token here would expose it in a ConfigMap. An existing block is replaced
    # because Backstage replaces arrays when config files are merged.
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        yq -i '.integrations.github = [{"host": "github.com", "token": "${GITHUB_TOKEN}"}]' "$output"
    fi
}
