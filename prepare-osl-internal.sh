#!/bin/bash
#
# Prepare pre-release OSL images for testing on an OpenShift cluster:
#   1) Mirror required images into the internal registry (single-arch by default)
#   2) Build a rewritten internal logic-only catalog image (hosted-compatible)
#   3) Create CatalogSource pointing at the rewritten internal catalog
#   4) Wait for CatalogSource to become READY
#   5) Write .env.osl with OSL_* exports for setup-orchestrator.sh
#
# Requires: oc, podman, skopeo, jq
#
# Usage:
#   ./prepare-osl-internal.sh --release 1.39.0.CR1
#
# Env var output chain:
#   This script writes .env.osl with OSL_IIB_IMAGE, OSL_VERSION,
#   OSL_LOGIC_CSV, and OSL_CATALOG_SOURCE.
#
#   setup-orchestrator.sh sources .env.osl and translates these into
#   --logic-operator-* flags for install-orchestrator.sh, which uses
#   LOGIC_OPERATOR_SOURCE, LOGIC_OPERATOR_STARTING_CSV, etc.
#
#   The overlays e2e tests (workflow-deployment-helpers.ts) read
#   ORCH_E2E_LOGIC_OPERATOR_* env vars that map 1:1 to the same flags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_DIR="${SCRIPT_DIR}/config/osl-releases"
ENV_OSL_FILE="${SCRIPT_DIR}/.env.osl"

release=""
release_manifest=""
ocp_minor=""
mirror_namespace="osl-mirror"
multi_arch=false
SKOPEO_RETRY_TIMES="${SKOPEO_RETRY_TIMES:-3}"
CATALOGSOURCE_READY_TIMEOUT="${CATALOGSOURCE_READY_TIMEOUT:-600}"
ENFORCE_DIGEST_PINNING="${ENFORCE_DIGEST_PINNING:-0}"

INTERNAL_REGISTRY_SERVICE="image-registry.openshift-image-registry.svc:5000"
CATALOGSOURCE_NAME="osl-custom-catalog"
DEST_REPOS=()
BUNDLE_DIGEST_PIN=""

PULLER_GROUPS=(
    "system:serviceaccounts:openshift-marketplace"
    "system:serviceaccounts:openshift-operators"
    "system:serviceaccounts:openshift-serverless"
    "system:serviceaccounts:openshift-serverless-logic"
)
rhdh_namespace="orchestrator"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 --release <version> [options]

Required:
  --release <version>           Release name (loads config/osl-releases/<version>.json)

Options:
  --release-manifest <path>     Explicit manifest JSON path (overrides --release lookup)
  --ocp-minor <major.minor>     Override detected cluster version (e.g. 4.17)
  --mirror-namespace <name>     Internal registry project (default: osl-mirror)
  --namespace <name>            RHDH namespace granted image-puller on the mirror (default: orchestrator)
  --multi-arch                  Mirror all architectures (default: amd64 only)
  -h, --help                    Show this help
EOF
}

log() { echo "==> $*"; }

die() { echo "Error: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_cluster_access() {
    oc whoami >/dev/null 2>&1 || die "Cannot reach OpenShift cluster. Run: oc login <cluster-api>"
}

detect_ocp_minor() {
    local full
    full="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
    [[ -z "$full" ]] && die "Could not detect cluster version. Pass --ocp-minor manually."
    echo "$full" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
}

ensure_internal_registry_route() {
    oc patch configs.imageregistry.operator.openshift.io cluster \
        -p '{"spec":{"defaultRoute":true}}' --type=merge \
        -n openshift-image-registry >/dev/null 2>&1
    local host
    host="$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}' 2>/dev/null || true)"
    [[ -z "$host" ]] && die "Could not resolve internal registry route."
    echo "$host"
}

wait_for_internal_registry_ready() {
    local registry_host="$1"
    local timeout_secs="${2:-300}"
    local start
    start="$(date +%s)"

    log "Waiting for internal registry deployment rollout..."
    oc rollout status deployment/image-registry -n openshift-image-registry --timeout="${timeout_secs}s" >/dev/null

    log "Waiting for internal registry route to serve /v2/..."
    while true; do
        local code
        code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${registry_host}/v2/" || true)"
        if [[ "$code" == "200" || "$code" == "401" ]]; then
            return 0
        fi
        if (( $(date +%s) - start >= timeout_secs )); then
            die "internal registry route did not become ready (last HTTP status: ${code:-none})"
        fi
        sleep 5
    done
}

login_internal_registry() {
    local registry_host="$1"
    local cluster_user="$2"
    local token="$3"

    log "Logging into internal registry (tls-verify=true): ${registry_host}"
    if podman login -u "$cluster_user" -p "$token" --tls-verify=true "$registry_host" >/dev/null 2>&1; then
        return 0
    fi

    log "TLS-verified login failed; retrying with tls-verify=false for ${registry_host}"
    podman login -u "$cluster_user" -p "$token" --tls-verify=false "$registry_host" >/dev/null
}

ensure_pull_access() {
    local ns="$1"
    log "Granting image-puller RBAC in namespace: ${ns}"
    local groups=("${PULLER_GROUPS[@]}")
    if [[ -n "${rhdh_namespace}" ]]; then
        groups+=("system:serviceaccounts:${rhdh_namespace}")
    fi
    local group
    for group in "${groups[@]}"; do
        oc policy add-role-to-group system:image-puller "$group" -n "$ns" >/dev/null 2>&1 || true
    done
}

update_cluster_pull_secret() {
    local route_host="$1" cluster_user="$2"
    local auth tmp_current tmp_updated
    auth="$(printf '%s' "${cluster_user}:$(oc whoami -t)" | base64 -w0)"
    tmp_current="$(mktemp)"; tmp_updated="$(mktemp)"
    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$tmp_current"
    jq --arg auth "$auth" --arg rh "$route_host" --arg sh "$INTERNAL_REGISTRY_SERVICE" '
        .auths[$rh] = {"auth": $auth, "email": "unused@example.com"} |
        .auths[$sh] = {"auth": $auth, "email": "unused@example.com"}
    ' "$tmp_current" > "$tmp_updated"
    if ! cmp -s "$tmp_current" "$tmp_updated"; then
        oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$tmp_updated" >/dev/null
        log "Updated cluster pull-secret with internal registry auth."
    fi
    rm -f "$tmp_current" "$tmp_updated"
}

to_repo_name() {
    local ref="$1"
    echo "${ref%%@*}" | sed 's|.*/||'
}

sed_escape_ere() {
    printf '%s' "$1" | sed -e 's/[][(){}.^$|*+?\\]/\\&/g'
}

sed_escape_repl() {
    printf '%s' "$1" | sed -e 's/[&\\#]/\\&/g'
}

# Rewrite OSL image refs under a directory to the internal mirror.
# If bundle_digest is sha256:..., catalog bundle images use that digest;
# all other mirrored repos are rewritten to the :mirror tag (hosted clusters
# cannot use IDMS, and internal-registry digests do not match upstream).
rewrite_osl_refs_in_dir() {
    local root="$1"
    local bundle_digest="${2:-}"
    local internal="$INTERNAL_REGISTRY_SERVICE"
    local ns="$mirror_namespace"
    local prefix="${internal}/${ns}"
    local prefix_esc old_esc dest_esc name_esc dest file tmp count=0
    local -a names=()

    prefix_esc="$(sed_escape_ere "$prefix")"
    if ((${#DEST_REPOS[@]} > 0)); then
        mapfile -t names < <(printf '%s\n' "${DEST_REPOS[@]}" | awk '{ print length, $0 }' | sort -nr | cut -d' ' -f2-)
    fi

    while IFS= read -r -d '' file; do
        tmp="$(mktemp)"
        old_esc="$(sed_escape_ere "registry.redhat.io/openshift-serverless-1/")"
        dest_esc="$(sed_escape_repl "${prefix}/openshift-serverless-1-")"
        sed -E "s#${old_esc}#${dest_esc}#g" "$file" > "$tmp"

        old_esc="$(sed_escape_ere "registry.stage.redhat.io/openshift-serverless-1/")"
        dest_esc="$(sed_escape_repl "${prefix}/openshift-serverless-1-")"
        sed -E -i "s#${old_esc}#${dest_esc}#g" "$tmp"

        old_esc="$(sed_escape_ere "registry-proxy.engineering.redhat.com/rh-osbs/")"
        dest_esc="$(sed_escape_repl "${prefix}/")"
        sed -E -i "s#${old_esc}#${dest_esc}#g" "$tmp"

        for name in "${names[@]}"; do
            [[ -n "$name" ]] || continue
            if [[ "$bundle_digest" == sha256:* && "$name" == *bundle* ]]; then
                dest="${prefix}/${name}@${bundle_digest}"
            else
                dest="${prefix}/${name}:mirror"
            fi
            name_esc="$(sed_escape_ere "$name")"
            dest_esc="$(sed_escape_repl "$dest")"
            sed -E -i \
                "s#${prefix_esc}/${name_esc}(@sha256:[a-fA-F0-9]+|:[A-Za-z0-9._-]+)?#${dest_esc}#g" \
                "$tmp"
        done

        if ! cmp -s "$file" "$tmp"; then
            cat "$tmp" > "$file"
            count=$((count + 1))
        fi
        rm -f "$tmp"
    done < <(find "$root" -type f -print0)

    echo "rewritten files: ${count}"
}

# ---------------------------------------------------------------------------
# Mirror a single image with retry and exponential backoff
# ---------------------------------------------------------------------------
mirror_image() {
    local source_ref="$1" push_ref="$2"

    if skopeo inspect --no-tags --tls-verify=false "docker://${push_ref}" >/dev/null 2>&1; then
        log "  already present, skipping copy"
        return 0
    fi

    local skopeo_args=(copy --preserve-digests --retry-times "$SKOPEO_RETRY_TIMES"
        --dest-tls-verify=false)
    if [[ "$multi_arch" == "true" ]]; then
        skopeo_args+=(--all)
    else
        skopeo_args+=(--override-arch amd64 --override-os linux)
    fi

    local attempt=0 max_attempts=3 wait_secs=10
    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))
        if skopeo "${skopeo_args[@]}" "docker://${source_ref}" "docker://${push_ref}" >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            log "  Retry ${attempt}/${max_attempts} in ${wait_secs}s..."
            sleep "$wait_secs"
            wait_secs=$((wait_secs * 2))
        fi
    done
    die "Failed to mirror ${source_ref} after ${max_attempts} attempts"
}

rewrite_operator_bundle_csv() {
    local registry_host="$1"
    local bundle_name=""
    local i
    for i in "${!image_names[@]}"; do
        if [[ "${image_names[$i]}" == *bundle* ]]; then
            bundle_name="$(to_repo_name "${image_sources[$i]}")"
            break
        fi
    done
    [[ -n "$bundle_name" ]] || { log "no operator-bundle image; skipping bundle CSV rewrite"; return 0; }

    local source="${registry_host}/${mirror_namespace}/${bundle_name}:mirror"
    local workdir
    workdir="$(mktemp -d)"
    log "Rewriting operator-bundle CSV images in ${bundle_name}:mirror"
    local cid
    cid="$(podman create --tls-verify=false "$source" 2>/dev/null || podman create "$source")"
    podman cp "${cid}:/manifests" "${workdir}/manifests"
    podman cp "${cid}:/metadata" "${workdir}/metadata" >/dev/null 2>&1 || true
    podman rm "$cid" >/dev/null

    rewrite_osl_refs_in_dir "$workdir" ""

    {
        echo "FROM ${source}"
        echo "COPY manifests /manifests"
        [[ -d "${workdir}/metadata" ]] && echo "COPY metadata /metadata"
    } > "${workdir}/Dockerfile"
    podman build -t "$source" "$workdir" >/dev/null
    podman push --tls-verify=false "$source" >/dev/null
    BUNDLE_DIGEST_PIN="$(skopeo inspect --no-tags --tls-verify=false "docker://${source}" | jq -r '.Digest // empty')"
    [[ "$BUNDLE_DIGEST_PIN" == sha256:* ]] || die "could not inspect rewritten bundle digest for ${source}"
    log "Pushed rewritten operator-bundle: ${source} (${BUNDLE_DIGEST_PIN})"
    rm -rf "$workdir"
}

build_rewritten_logic_catalog() {
    local registry_host="$1"
    local iib_image_route="$2"
    local rewritten_tag="logic-operator-catalog:rewritten"
    local rewritten_route="${registry_host}/${mirror_namespace}/${rewritten_tag}"

    local workdir
    workdir="$(mktemp -d)"

    log "Extracting file-based catalog configs from mirrored IIB..."
    local cid
    cid="$(podman create "${iib_image_route}")"
    podman cp "${cid}":/configs "${workdir}/configs"
    podman rm "${cid}" >/dev/null

    find "${workdir}/configs" -mindepth 1 -maxdepth 1 -type d ! -name 'logic-operator' -exec rm -rf {} +

    [[ -d "${workdir}/configs/logic-operator" ]] || die "logic-operator package not found in extracted catalog configs"
    rewrite_osl_refs_in_dir "${workdir}/configs" "$BUNDLE_DIGEST_PIN"

    cat > "${workdir}/Dockerfile" <<'EOF'
FROM quay.io/operator-framework/opm:latest
COPY configs /configs
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache", "--cache-enforce-integrity=false"]
EOF

    log "Building rewritten logic-only catalog image..."
    podman build -t "${rewritten_route}" "${workdir}" >/dev/null
    podman push --tls-verify=false "${rewritten_route}" >/dev/null
    log "Pushed rewritten catalog image: ${rewritten_route}"

    OSL_IIB_IMAGE="${INTERNAL_REGISTRY_SERVICE}/${mirror_namespace}/${rewritten_tag}"
    rm -rf "${workdir}"
}

# ---------------------------------------------------------------------------
# CatalogSource
# ---------------------------------------------------------------------------
create_catalogsource() {
    local iib_image="$1"
    log "Creating CatalogSource ${CATALOGSOURCE_NAME} -> ${iib_image}"
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${iib_image}
  displayName: OSL Pre-release Catalog
  publisher: Pre-release Testing
EOF
}

wait_for_catalogsource_ready() {
    log "Waiting for CatalogSource ${CATALOGSOURCE_NAME} to become READY (timeout ${CATALOGSOURCE_READY_TIMEOUT}s)..."
    local start elapsed state
    start=$(date +%s)
    while true; do
        state="$(oc get catalogsource "$CATALOGSOURCE_NAME" -n openshift-marketplace \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
        if [[ "$state" == "READY" ]]; then
            log "CatalogSource ${CATALOGSOURCE_NAME} is READY."
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= CATALOGSOURCE_READY_TIMEOUT )); then
            echo "CatalogSource status: ${state:-unknown}" >&2
            oc get catalogsource "$CATALOGSOURCE_NAME" -n openshift-marketplace -o yaml >&2 || true
            die "CatalogSource ${CATALOGSOURCE_NAME} did not become READY within ${CATALOGSOURCE_READY_TIMEOUT}s"
        fi
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)          release="${2:-}"; shift 2 ;;
        --release-manifest) release_manifest="${2:-}"; shift 2 ;;
        --ocp-minor)        ocp_minor="${2:-}"; shift 2 ;;
        --mirror-namespace) mirror_namespace="${2:-}"; shift 2 ;;
        --namespace)        rhdh_namespace="${2:-}"; shift 2 ;;
        --multi-arch)       multi_arch=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "unknown option: $1" ;;
    esac
done

[[ -z "$release" && -z "$release_manifest" ]] && { usage; die "specify --release or --release-manifest."; }

for cmd in oc podman skopeo jq; do
    require_cmd "$cmd"
done

ensure_cluster_access

[[ -z "$ocp_minor" ]] && ocp_minor="$(detect_ocp_minor)"
[[ "$ocp_minor" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid --ocp-minor '$ocp_minor' (expected e.g. 4.17)"

# Resolve manifest
if [[ -n "$release_manifest" ]]; then
    manifest_file="$release_manifest"
else
    manifest_file="${RELEASES_DIR}/${release}.json"
fi
[[ -f "$manifest_file" ]] || die "manifest not found: $manifest_file"
jq -e . "$manifest_file" >/dev/null 2>&1 || die "invalid JSON: $manifest_file"
[[ -z "$release" ]] && release="$(jq -r '.version // empty' "$manifest_file")"

# Read manifest fields: .iib{"4.17": "..."}, .images[{source, name}]
iib_source="$(jq -r --arg ocp "$ocp_minor" '.iib[$ocp] // empty' "$manifest_file")"
[[ -z "$iib_source" ]] && die "manifest has no IIB for OCP ${ocp_minor}. Available: $(jq -r '.iib | keys | join(", ")' "$manifest_file")"

osl_version="$(jq -r '.version // empty' "$manifest_file")"
osl_version_short="$(echo "$osl_version" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"

mapfile -t image_sources < <(jq -r '.images[].source' "$manifest_file")
mapfile -t image_names < <(jq -r '.images[].name' "$manifest_file")
(( ${#image_sources[@]} > 0 )) || die "manifest contains no images"

release_slug="$(echo "$release" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
iib_repo_name="osl-iib-${release_slug}-ocp-${ocp_minor//./-}"

log "Release:    ${release}"
log "OCP:        ${ocp_minor}"
log "IIB:        ${iib_source}"
log "Images:     ${#image_sources[@]}"
log "Arch:       $(if [[ "$multi_arch" == "true" ]]; then echo "multi"; else echo "amd64"; fi)"
log "Mode:       rewrite-catalog (default)"

if [[ "$iib_source" != *@sha256:* ]]; then
    if [[ "$ENFORCE_DIGEST_PINNING" == "1" ]]; then
        die "IIB image must be digest-pinned when ENFORCE_DIGEST_PINNING=1: ${iib_source}"
    fi
    log "WARNING: IIB image is not digest-pinned: ${iib_source}"
fi
for src in "${image_sources[@]}"; do
    if [[ "$src" != *@sha256:* ]]; then
        if [[ "$ENFORCE_DIGEST_PINNING" == "1" ]]; then
            die "Manifest image is not digest-pinned while ENFORCE_DIGEST_PINNING=1: ${src}"
        fi
        log "WARNING: image source is not digest-pinned: ${src}"
    fi
done

# ---------------------------------------------------------------------------
# Setup registry access
# ---------------------------------------------------------------------------
registry_host="$(ensure_internal_registry_route)"
cluster_user="$(oc whoami)"
cluster_token="$(oc whoami -t)"
wait_for_internal_registry_ready "$registry_host"

oc new-project "$mirror_namespace" >/dev/null 2>&1 || oc project "$mirror_namespace" >/dev/null 2>&1 || true
ensure_pull_access "$mirror_namespace"
update_cluster_pull_secret "$registry_host" "$cluster_user"

login_internal_registry "$registry_host" "$cluster_user" "$cluster_token"

# ---------------------------------------------------------------------------
# Mirror images
# ---------------------------------------------------------------------------
for i in "${!image_sources[@]}"; do
    src="${image_sources[$i]}"
    name="${image_names[$i]}"
    # Destination repo must match the original image name so the rewritten
    # catalog (registry-proxy.../rh-osbs/<name>@sha256) can pull from osl-mirror.
    repo_name="$(to_repo_name "$src")"
    push_ref="${registry_host}/${mirror_namespace}/${repo_name}:mirror"

    log "Mirroring [$(( i + 1 ))/${#image_sources[@]}] ${name} -> ${repo_name}"
    mirror_image "$src" "$push_ref"
    DEST_REPOS+=("$repo_name")
done

log "Mirroring IIB -> ${iib_repo_name}"
mirror_image "$iib_source" "${registry_host}/${mirror_namespace}/${iib_repo_name}:mirror"

rewrite_operator_bundle_csv "$registry_host"

# ---------------------------------------------------------------------------
# Hosted-compatible rewrite catalog path (default)
# ---------------------------------------------------------------------------
OSL_IIB_IMAGE="${INTERNAL_REGISTRY_SERVICE}/${mirror_namespace}/${iib_repo_name}:mirror"
build_rewritten_logic_catalog "${registry_host}" "${registry_host}/${mirror_namespace}/${iib_repo_name}:mirror"

# ---------------------------------------------------------------------------
# CatalogSource + wait for READY
# ---------------------------------------------------------------------------
create_catalogsource "$OSL_IIB_IMAGE"
oc delete pod -n openshift-marketplace -l "olm.catalogSource=${CATALOGSOURCE_NAME}" --ignore-not-found >/dev/null 2>&1 || true
wait_for_catalogsource_ready

if oc get csv -n openshift-operators -o name 2>/dev/null | grep -q logic-operator; then
    log "Removing existing logic-operator CSV/subscription so OLM installs from the rewritten bundle"
    oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | grep '^logic-operator' \
        | xargs -r oc delete csv -n openshift-operators --ignore-not-found
    oc delete subscription.operators.coreos.com logic-operator -n openshift-operators --ignore-not-found >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Write .env.osl
# ---------------------------------------------------------------------------
OSL_LOGIC_CSV="$(jq -r '.logic_csv // empty' "$manifest_file")"
if [[ -z "$OSL_LOGIC_CSV" ]]; then
    OSL_LOGIC_CSV="logic-operator.v${osl_version_short}.0"
fi
cat > "$ENV_OSL_FILE" <<EOF
export OSL_IIB_IMAGE="${OSL_IIB_IMAGE}"
export OSL_VERSION="${osl_version}"
export OSL_LOGIC_CSV="${OSL_LOGIC_CSV}"
export OSL_CATALOG_SOURCE="${CATALOGSOURCE_NAME}"
EOF

log "Wrote ${ENV_OSL_FILE}"
echo ""
echo "Preparation complete. Source the env file before deploying:"
echo "  source ${ENV_OSL_FILE}"
echo ""
echo "  OSL_IIB_IMAGE=${OSL_IIB_IMAGE}"
echo "  OSL_VERSION=${osl_version}"
echo "  OSL_LOGIC_CSV=${OSL_LOGIC_CSV}"
echo "  OSL_CATALOG_SOURCE=${CATALOGSOURCE_NAME}"
