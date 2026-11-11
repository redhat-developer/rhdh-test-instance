#!/usr/bin/env bash

# =============================================================================
# setup-resources.sh — Cluster resources shared by every deployment method
#
# Creates the namespace-scoped resources an RHDH instance needs regardless of
# which optional plugins are enabled:
#   - rhdh-secrets (base URL, session/backend/MCP secrets, GitHub token)
#   - app-config-rhdh and dynamic-plugins ConfigMaps (merged at deploy time)
#   - catalog entity ConfigMaps
#   - image stream pre-imports and demo workloads
#
# The app-config and dynamic-plugins ConfigMaps are built by deploy.sh from the
# base configuration plus the selected plugins. APP_CONFIG_FILE and
# DYNAMIC_PLUGINS_FILE point at those generated files.
# =============================================================================

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$DIR")"

_random_secret() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"
}

# =============================================================================
# RHDH Secrets
#
# Plugin scripts patch their own keys in later (Keycloak, Lighthouse, Scorecard).
# =============================================================================
create_rhdh_secrets() {
  echo ""
  echo "Creating rhdh-secrets Secret..."

  : "${RHDH_BASE_URL:?RHDH_BASE_URL must be set before setup-resources.sh runs}"

  if oc get secret rhdh-secrets --namespace="${NAMESPACE}" &>/dev/null; then
    # Keep existing values; only refresh the URL and ensure the secrets that the
    # configuration references are present. An explicitly supplied MCP_TOKEN
    # overrides the stored one.
    local backend_secret mcp_token
    backend_secret=$(oc get secret rhdh-secrets -n "${NAMESPACE}" -o jsonpath='{.data.BACKEND_SECRET}' 2>/dev/null \
      | (base64 -d 2>/dev/null || true))
    [[ -n "$backend_secret" ]] || backend_secret=$(_random_secret)
    mcp_token=$(oc get secret rhdh-secrets -n "${NAMESPACE}" -o jsonpath='{.data.MCP_TOKEN}' 2>/dev/null \
      | (base64 -d 2>/dev/null || true))
    mcp_token="${MCP_TOKEN:-${mcp_token:-$(_random_secret)}}"

    jq -n --arg url "$RHDH_BASE_URL" --arg backend "$backend_secret" --arg mcp "$mcp_token" \
      '{stringData: {RHDH_BASE_URL: $url, BACKEND_SECRET: $backend, MCP_TOKEN: $mcp}}' \
      | oc patch secret rhdh-secrets -n "${NAMESPACE}" --type=merge --patch-file=/dev/stdin
    echo "rhdh-secrets already exists — refreshed RHDH_BASE_URL, BACKEND_SECRET and MCP_TOKEN."
  else
    oc create secret generic rhdh-secrets \
      --from-literal=RHDH_BASE_URL="${RHDH_BASE_URL}" \
      --from-literal=SESSION_SECRET="$(_random_secret)" \
      --from-literal=BACKEND_SECRET="$(_random_secret)" \
      --from-literal=MCP_TOKEN="${MCP_TOKEN:-$(_random_secret)}" \
      --from-literal=KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-}" \
      --from-literal=KEYCLOAK_METADATA_URL="${KEYCLOAK_METADATA_URL:-}" \
      --from-literal=KEYCLOAK_LOGIN_REALM="${KEYCLOAK_LOGIN_REALM:-}" \
      --from-literal=KEYCLOAK_REALM="${KEYCLOAK_REALM:-}" \
      --from-literal=KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-}" \
      --from-literal=KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-}" \
      --from-literal=LIGHTHOUSE_URL="${LIGHTHOUSE_URL:-}" \
      --from-literal=LIGHTHOUSE_SVC_URL="${LIGHTHOUSE_SVC_URL:-}" \
      --namespace="${NAMESPACE}"

    echo "rhdh-secrets created!"
  fi

  # Optional GitHub token, opt-in through RHDH_GITHUB_TOKEN so a GITHUB_TOKEN
  # exported for other tools is never copied into the cluster. It enables
  # private catalog locations, bulk import and write operations; public access
  # remains the default.
  if [[ -n "${RHDH_GITHUB_TOKEN:-}" ]]; then
    jq -n --arg token "$RHDH_GITHUB_TOKEN" '{stringData: {GITHUB_TOKEN: $token}}' \
      | oc patch secret rhdh-secrets -n "${NAMESPACE}" --type=merge --patch-file=/dev/stdin
    echo "GitHub token configured from RHDH_GITHUB_TOKEN."
  fi
}

# =============================================================================
# RHDH ConfigMaps
# =============================================================================
apply_rhdh_configmaps() {
  echo ""
  echo "Applying RHDH ConfigMaps..."

  local app_config="${APP_CONFIG_FILE:-${ROOT_DIR}/config/app-config-rhdh.yaml}"
  local dynamic_plugins="${DYNAMIC_PLUGINS_FILE:-${ROOT_DIR}/config/dynamic-plugins.yaml}"

  oc create configmap app-config-rhdh \
    --from-file=app-config-rhdh.yaml="${app_config}" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"

  # Replace instead of apply: dynamic plugin lists must not accumulate between
  # repeated deployments.
  oc create configmap dynamic-plugins \
    --from-file=dynamic-plugins.yaml="${dynamic_plugins}" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | oc replace --force -f - --namespace="${NAMESPACE}"

  echo "RHDH ConfigMaps applied!"
}

# =============================================================================
# Catalog Entities
#
# Applied unconditionally so the catalog is populated regardless of which
# plugins are enabled.
# =============================================================================
apply_catalog_entities() {
  echo ""
  echo "Applying catalog entity ConfigMaps..."

  local catalog_dir="${ROOT_DIR}/resources/catalog-entities"
  local yaml_file

  for yaml_file in "${catalog_dir}"/*.yaml; do
    echo "  Applying: $(basename "$yaml_file")"
    envsubst '${RHDH_BASE_URL} ${NAMESPACE} ${KEYCLOAK_NS}' < "${yaml_file}" | oc apply -f - --namespace="${NAMESPACE}"
  done

  echo "Catalog entities applied!"
}

# =============================================================================
# Image Stream Imports
#
# Pre-import container images from external registries to avoid rate-limit
# failures during plugin deployment.
# =============================================================================
apply_image_stream_imports() {
  echo ""
  echo "Applying image stream imports..."

  local image_stream_dir="${ROOT_DIR}/resources/image-stream-imports"
  local yaml_file name

  if [[ ! -d "$image_stream_dir" ]] || [[ -z "$(ls -A "$image_stream_dir" 2>/dev/null)" ]]; then
    echo "  No image stream imports found — skipping."
    return 0
  fi

  for yaml_file in "${image_stream_dir}"/*.yaml; do
    name=$(basename "$yaml_file")
    echo "  Applying: ${name}"
    oc apply -f "${yaml_file}" --namespace="${NAMESPACE}" || \
      echo "  Warning: Failed to apply ${name} — continuing."
  done

  echo "Image stream imports applied!"
}

# =============================================================================
# Demo Resources
#
# Lightweight example workloads that populate the Topology and Kubernetes views.
# =============================================================================
apply_demo_resources() {
  echo ""
  echo "Applying demo resources..."

  local examples_dir="${ROOT_DIR}/resources/rhdh-script-examples"
  local yaml_file name

  if [[ ! -d "$examples_dir" ]] || [[ -z "$(ls -A "$examples_dir" 2>/dev/null)" ]]; then
    echo "  No demo resources found — skipping."
    return 0
  fi

  for yaml_file in "${examples_dir}"/*.yaml; do
    name=$(basename "$yaml_file")
    echo "  Applying: ${name}"
    oc apply -f "${yaml_file}" --namespace="${NAMESPACE}" || \
      echo "  Warning: Failed to apply ${name} — continuing."
  done

  echo "Demo resources applied!"
}

# =============================================================================
# Teardown
# =============================================================================
teardown_resources() {
  echo ""
  echo "=============================================="
  echo "Resource Teardown"
  echo "=============================================="

  local catalog_dir="${ROOT_DIR}/resources/catalog-entities"
  local yaml_file

  echo "Removing rhdh-secrets Secret..."
  oc delete secret rhdh-secrets --namespace="${NAMESPACE}" 2>/dev/null || true

  echo "Removing RHDH ConfigMaps and secrets..."
  oc delete configmap app-config-rhdh dynamic-plugins intelligent-assistant-stack \
    --namespace="${NAMESPACE}" 2>/dev/null || true
  oc delete secret intelligent-assistant-secrets --namespace="${NAMESPACE}" 2>/dev/null || true
  oc delete networkpolicy rhdh-lighthouse-egress rhdh-intelligent-assistant-egress rhdh-keycloak-egress \
    --namespace="${NAMESPACE}" 2>/dev/null || true

  echo "Removing catalog entity ConfigMaps..."
  for yaml_file in "${catalog_dir}"/*.yaml; do
    oc delete -f "${yaml_file}" --namespace="${NAMESPACE}" 2>/dev/null || true
  done

  echo "Removing RBAC policy ConfigMap..."
  oc delete -f "${ROOT_DIR}/resources/rbac/rbac-policies.yaml" \
    --namespace="${NAMESPACE}" 2>/dev/null || true

  echo "Removing cluster-scoped resources for this instance..."
  # Cluster-scoped, so it survives namespace deletion. Removed here so a
  # teardown without --plugins kubernetes does not leave it behind.
  oc delete clusterrolebinding "rhdh-kubernetes-plugin-${NAMESPACE}" 2>/dev/null || true

  echo "Removing demo resources..."
  local examples_dir="${ROOT_DIR}/resources/rhdh-script-examples"
  if [[ -d "$examples_dir" ]]; then
    for yaml_file in "${examples_dir}"/*.yaml; do
      oc delete -f "${yaml_file}" --namespace="${NAMESPACE}" 2>/dev/null || true
    done
  fi

  echo ""
  echo "Resource teardown complete."
}

setup_resources() {
  echo ""
  echo "=============================================="
  echo "Resource Setup"
  echo "=============================================="

  # Shared Keycloak namespace, used by the catalog entities.
  export KEYCLOAK_NS="${KEYCLOAK_NS:-rhdh-keycloak}"

  create_rhdh_secrets
  apply_rhdh_configmaps
  apply_catalog_entities
  apply_image_stream_imports
  apply_demo_resources

  echo ""
  echo "Resource setup complete."
}

main() {
  : "${NAMESPACE:?NAMESPACE must be set. Export it or pass it: NAMESPACE=rhdh ./scripts/setup-resources.sh}"

  if [[ "${TEARDOWN:-false}" == "true" ]]; then
    teardown_resources
  else
    setup_resources
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
