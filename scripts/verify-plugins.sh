#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# verify-plugins.sh — Validate the plugin configuration before deploying
#
# Renders the Helm deployment with the real chart values, then runs the same
# dynamic plugin installer that the init container runs, using the same RHDH
# image and plugin catalog. This catches:
#   - ref:// entries that the selected catalog cannot resolve
#   - conflicting or duplicate plugin entries
#   - plugin images that cannot be pulled
#   - pinned overlay images (bs_<backstage>__) out of sync with the release
#
# Requires: helm, yq, jq and podman (or docker) with network access.
#
# --native runs the installer through npx with the host's skopeo instead of the
# container. It is much faster on Apple Silicon, where the amd64 image has to be
# emulated, but the container run is the authoritative check.
#
# Usage:
#   scripts/verify-plugins.sh [--version <version>] [--plugins <list>] [--chart <tag>] [--native]
# =============================================================================

version="2.2"
plugins="${PLUGINS:-}"
chart_version=""
chart_override=""
native=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --plugins) plugins="$2"; shift 2 ;;
        --chart)   chart_override="$2"; shift 2 ;;
        --native)  native=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

source "$(dirname "${BASH_SOURCE[0]}")/deployment-common.sh"

# Installer package used by --native. The container run uses the image's own copy.
INSTALLER_PACKAGE="${INSTALLER_PACKAGE:-@red-hat-developer-hub/cli-module-install-dynamic-plugins@0.6.1}"
parse_rhdh_version "$version"
resolve_plugins "$plugins"
prepare_deploy_workdir

if [[ "$native" == "true" ]]; then
    command -v node >/dev/null || die "Node.js is required for --native."
    command -v npx >/dev/null || die "npx is required for --native."
    command -v skopeo >/dev/null || die "skopeo is required for --native."
    node_major=$(node -p 'process.versions.node.split(".")[0]')
    (( node_major >= 22 )) || die "Node.js 22 or newer is required for --native (found ${node_major})."
elif command -v podman >/dev/null; then
    container_tool=podman
elif command -v docker >/dev/null; then
    container_tool=docker
else
    die "podman or docker is required to run the plugin installer (or use --native)."
fi

chart_version="${chart_override:-$(resolve_helm_chart_version "$version")}"
[[ -n "$chart_version" ]] || die "Could not resolve a Helm chart version for '${version}'."
if [[ -n "${chart_override}" ]]; then
    helm show chart oci://quay.io/rhdh/chart --version "$chart_version" >/dev/null 2>&1 || \
        die "Helm chart '${chart_version}' is not published. See https://quay.io/repository/rhdh/chart?tab=tags"
else
    validate_helm_chart_version "$version" "$chart_version"
fi

echo "Verifying RHDH ${version} (chart ${chart_version}) with plugins: ${PLUGINS_RESOLVED}"

# ── Build the merged configuration and render the deployment ──────────────────
export APP_CONFIG_FILE="${DEPLOY_WORKDIR}/app-config-rhdh.yaml"
export DYNAMIC_PLUGINS_FILE="${DEPLOY_WORKDIR}/dynamic-plugins.yaml"
build_app_config "$APP_CONFIG_FILE"
build_dynamic_plugins "$DYNAMIC_PLUGINS_FILE"

rendered="${DEPLOY_WORKDIR}/rendered.yaml"
echo "Rendering Helm chart ${chart_version}..."
RHDH_RENDER_ONLY=true \
RESOLVED_HELM_CHART_VERSION="$chart_version" \
CLUSTER_ROUTER_BASE=apps.example.test \
NAMESPACE=verify \
bash "${DEPLOY_ROOT}/helm/deploy.sh" verify "$version" > "$rendered"

# ── Extract the images and the plugin list from the rendered manifests ────────
rendered_json="${DEPLOY_WORKDIR}/rendered.json"
yq eval-all -o=json '[.]' "$rendered" > "$rendered_json"

image=$(jq -er '
    [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[] |
     select(.name == "backstage-backend") | .image] | first' "$rendered_json")
catalog_image=$(jq -er '
    [.[] | select(.kind == "Deployment") | .spec.template.spec.initContainers[]? |
     select(.name == "install-dynamic-plugins") | .env[] | select(.name == "CATALOG_INDEX_IMAGE") | .value] | first' "$rendered_json")
[[ -n "$catalog_image" && "$catalog_image" != "null" ]] || die "The rendered deployment has no CATALOG_INDEX_IMAGE."

echo "RHDH image:     ${image}"
echo "Plugin catalog: ${catalog_image}"

# The chart merges its own component plugins into the ConfigMap; use exactly
# what the deployment will install.
install_dir="${DEPLOY_WORKDIR}/install"
mkdir -p "$install_dir" "${install_dir}/tmp"
jq -r '
    [.[] | select(.kind == "ConfigMap") | .data["dynamic-plugins.yaml"] |
     select(. != null)] | first' "$rendered_json" > "${install_dir}/dynamic-plugins.yaml"
[[ -s "${install_dir}/dynamic-plugins.yaml" ]] || die "The rendered deployment has no dynamic-plugins ConfigMap."

# ── Run the real installer ───────────────────────────────────────────────────
if [[ "$native" == "true" ]]; then
    echo "Running the dynamic plugin installer natively (npx)..."
    (
        cd "$install_dir"
        CATALOG_INDEX_IMAGE="$catalog_image" TMPDIR="${install_dir}/tmp" \
            npx -y "${INSTALLER_PACKAGE}" install "${install_dir}/dynamic-plugins-root"
    )
else
    echo "Running the dynamic plugin installer in ${image}..."
    container_args=(--rm --platform linux/amd64 -v "${install_dir}:/work:z" -w /work
        -e "CATALOG_INDEX_IMAGE=${catalog_image}" -e TMPDIR=/work/tmp
        --entrypoint /opt/app-root/src/install-dynamic-plugins.sh)
    if [[ "$container_tool" == "podman" ]]; then
        container_args+=(--userns=keep-id)
    fi
    "$container_tool" run "${container_args[@]}" "$image" /work/dynamic-plugins-root
fi

# ── Check pinned overlay plugin images against the release ───────────────────
bs_branch=$(upstream_branch_for rhdh)
bs_version=$(curl -fsSL "https://raw.githubusercontent.com/redhat-developer/rhdh/${bs_branch}/backstage.json" \
    | jq -r '.version // empty' || true)
if [[ -z "$bs_version" ]]; then
    bs_version=$("$container_tool" run --rm --platform linux/amd64 --entrypoint cat "$image" \
        /opt/app-root/src/backstage.json 2>/dev/null | jq -r '.version // empty' || true)
fi
[[ -n "$bs_version" ]] || die "Could not determine the Backstage version of ${version}."
echo "Backstage version: ${bs_version}"

pinned_versions=$(grep -oE 'bs_[0-9]+\.[0-9]+\.[0-9]+__' "${install_dir}/dynamic-plugins.yaml" | sort -u || true)
if [[ -n "$pinned_versions" ]]; then
    while read -r prefix; do
        [[ -z "$prefix" ]] && continue
        if [[ "$prefix" != "bs_${bs_version}__" ]]; then
            die "Pinned plugin images use ${prefix} but the release uses Backstage ${bs_version}. Update resources/*/dynamic-plugins.yaml."
        fi
    done <<< "$pinned_versions"
    echo "Pinned overlay images match Backstage ${bs_version}."
fi

# ── Check that product app.extensions defaults are restated ──────────────────
# Backstage replaces arrays when config files are merged, so any app.extensions
# entry here hides the product's list. The base config must restate it.
echo "Checking app.extensions against the product defaults..."
required_extensions="${DEPLOY_WORKDIR}/required-extensions.txt"
our_extensions="${DEPLOY_WORKDIR}/our-extensions.txt"
: > "$required_extensions"

product_branch_config="${DEPLOY_WORKDIR}/product-app-config.yaml"
curl -fsSL "https://raw.githubusercontent.com/redhat-developer/rhdh/${bs_branch}/app-config.yaml" \
    -o "$product_branch_config" || die "Could not fetch the product app-config.yaml for ${bs_branch}."
yq -o=json '.app.extensions // []' "$product_branch_config" \
    | jq -r '.[] | if type == "object" then keys[0] else . end' >> "$required_extensions"

installer_app_config="${install_dir}/dynamic-plugins-root/app-config.dynamic-plugins.yaml"
[[ -f "$installer_app_config" ]] || die "The plugin installer did not produce app-config.dynamic-plugins.yaml."
yq -o=json '.app.extensions // []' "$installer_app_config" \
    | jq -r '.[] | if type == "object" then keys[0] else . end' >> "$required_extensions"

# Compare extension types (keys), not values: the test instance overrides some
# values on purpose (for example page:home: false).
yq -o=json '.app.extensions // []' "$APP_CONFIG_FILE" \
    | jq -r '.[] | if type == "object" then keys[0] else . end' > "$our_extensions"
missing_default=0
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if ! grep -qxF -- "$entry" "$our_extensions"; then
        echo "  Missing product default in app.extensions: ${entry}" >&2
        missing_default=1
    fi
done < "$required_extensions"
if [[ "$missing_default" != "0" ]]; then
    die "config/app-config-rhdh.yaml must restate the product app.extensions defaults (arrays are replaced when config files are merged)."
fi
echo "app.extensions keeps the product defaults."

# ── Validate the Operator CR that will be applied ────────────────────────────
expected_orchestrator=false
expected_intelligent_assistant=false
plugin_enabled orchestrator && expected_orchestrator=true
plugin_enabled intelligent-assistant && expected_intelligent_assistant=true

RHDH_BASE_URL=https://rhdh.example.test \
    bash "${DEPLOY_ROOT}/operator/render-cr.sh" verify "$version" \
    | jq -e --argjson orchestrator "$expected_orchestrator" \
             --argjson intelligent_assistant "$expected_intelligent_assistant" '
        .apiVersion == "rhdh.redhat.com/v1alpha5" and
        all(.spec.flavours[];
            if .name == "orchestrator" then .enabled == $orchestrator
            elif .name == "intelligent-assistant" then .enabled == $intelligent_assistant
            else true end)
    ' >/dev/null
echo "Operator CR renders with the expected flavours."

echo ""
echo "Plugin configuration verified."
