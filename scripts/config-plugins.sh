#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
for file in "${DIR}"/plugins/*.sh; do source "$file"; done

# =============================================================================
# Shared helper: append a plugin's dynamic-plugins YAML to the cluster
# ConfigMap that was seeded in deploy.sh before plugin scripts ran.
# Both the current content and the new entries are concatenated so that
# multiple plugins can call this safely in sequence.
# =============================================================================
_append_plugin_dynamic_config() {
  local plugin_yaml_file="$1"
  local plugin_name="${2:-plugin}"

  echo "Appending ${plugin_name} dynamic-plugins config to cluster ConfigMap..."
  oc create configmap dynamic-plugins \
    --from-file=dynamic-plugins.yaml=<(
      oc get configmap dynamic-plugins \
        --namespace="${NAMESPACE}" \
        -o jsonpath='{.data.dynamic-plugins\.yaml}' \
        | sed 's/^plugins: \[\]/plugins:/'
      sed 's/^/  /' "${plugin_yaml_file}"
    ) \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"
}

# =============================================================================
# Setup/Teardown Functions for Each Category
# =============================================================================

declare -A CATEGORY_SETUP_FUNCTIONS=(
  [KEYCLOAK]="deploy_keycloak config_secrets_for_keycloak_plugins create_users_and_groups_keycloak apply_keycloak_labels"
  [LIGHTHOUSE]="deploy_lighthouse config_secrets_for_lighthouse_plugins apply_lighthouse_labels run_lighthouse_initial_scan"
)

declare -A CATEGORY_TEARDOWN_FUNCTIONS=(
  [KEYCLOAK]="uninstall_keycloak"
  [LIGHTHOUSE]="uninstall_lighthouse"
)

# =============================================================================
# Primary: resolve categories from a comma-separated plugin name list
# =============================================================================
# Plugin names are normalized: trimmed, uppercased, hyphens replaced with
# underscores. This means "keycloak", "KEYCLOAK", "lighthouse",
# "jfrog-artifactory", and "3scale" all resolve correctly.
# An unknown name emits a warning and is skipped rather than aborting.
# =============================================================================

resolve_categories_from_plugins() {
  local plugins_list="$1"
  local -A categories_found=()

  IFS=',' read -ra plugin_names <<< "$plugins_list"
  for name in "${plugin_names[@]}"; do
    local category
    category=$(echo "$name" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    if [[ -n "${CATEGORY_SETUP_FUNCTIONS[$category]+x}" ]]; then
      categories_found["$category"]=1
      echo "  ✓ Requested: $category"
    else
      echo "  ✗ Warning: Unknown plugin '${name}' (normalized: ${category}) — skipping"
    fi
  done

  ENABLED_CATEGORIES=("${!categories_found[@]}")
}


# =============================================================================
# Execute setup or teardown functions
# =============================================================================

execute_category_functions() {
  local function_map_name="$1"
  declare -n function_map="$function_map_name"
  
  if [[ ${#ENABLED_CATEGORIES[@]} -eq 0 ]]; then
    echo "No plugins requiring cluster resources detected."
    return 0
  fi
  
  # Track current step for round-robin execution
  declare -A current_step_index
  for category in "${ENABLED_CATEGORIES[@]}"; do
    current_step_index["$category"]=0
  done

  # Round-robin execution
  local all_complete=false
  while [[ "$all_complete" == "false" ]]; do
    all_complete=true
    for category in "${ENABLED_CATEGORIES[@]}"; do
      local functions="${function_map[$category]}"
      local steps=($functions)
      local step_index=${current_step_index[$category]}

      if [[ $step_index -lt ${#steps[@]} ]]; then
        local step="${steps[$step_index]}"
        if [[ "$step" != ":" ]]; then
          echo ""
          echo "[$category] Executing: $step"
          $step
        fi
        current_step_index["$category"]=$((step_index + 1))
        all_complete=false
      fi
    done
  done
}

# =============================================================================
# Main Entry Point
# =============================================================================
# Usage (from deploy.sh):   source scripts/config-plugins.sh; main "$PLUGINS"
# Usage (standalone):       ./scripts/config-plugins.sh keycloak,lighthouse
#
# $1 — required comma-separated plugin names, e.g. "keycloak,lighthouse"
#      Each plugin script appends its resources/*/dynamic-plugins.yaml to the
#      cluster's dynamic-plugins ConfigMap via _append_plugin_dynamic_config.
# =============================================================================
main() {
  local plugins_arg="${1:-}"

  echo ""
  echo "=============================================="
  echo "Plugin Configuration"
  echo "=============================================="

  if [[ -z "$plugins_arg" ]]; then
    echo "No plugins specified. Pass a comma-separated list, e.g: keycloak,lighthouse"
    return 0
  fi

  echo "Resolving plugins: ${plugins_arg}"
  echo ""
  resolve_categories_from_plugins "$plugins_arg"

  if [[ ${#ENABLED_CATEGORIES[@]} -eq 0 ]]; then
    echo "No recognised plugins to configure."
    return 0
  fi

  echo ""
  echo "Categories to configure: ${ENABLED_CATEGORIES[*]}"
  echo ""

  if [[ "${TEARDOWN:-false}" == "true" ]]; then
    echo "Running teardown..."
    execute_category_functions "CATEGORY_TEARDOWN_FUNCTIONS"
  else
    echo "Running setup..."
    execute_category_functions "CATEGORY_SETUP_FUNCTIONS"
  fi

  echo ""
  echo "=============================================="
  echo "Plugin configuration complete."
  echo "=============================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
