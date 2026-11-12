#!/usr/bin/env bash

# =============================================================================
# config-plugins.sh — Optional features ("plugins") for RHDH test instances
#
# Every optional feature is selected with --plugins / PLUGINS=<list> and may
# contribute:
#   resources/<name>/dynamic-plugins.yaml    dynamic plugin entries
#   resources/<name>/app-config.yaml         app-config merged into app-config-rhdh
#   resources/<name>/*.yaml                  resources applied by its functions
#   scripts/plugins/config-<name>-plugin.sh  setup/teardown functions
#
# Setup steps run round-robin so a plugin that waits for readiness does not
# block work on the other selected plugins.
# =============================================================================

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${DIR}/deployment-common.sh"
# shellcheck source=/dev/null
for file in "${DIR}"/plugins/*.sh; do source "$file"; done

# Plugin name -> setup functions. ":" marks a config-only plugin.
# shellcheck disable=SC2034 # used indirectly through a nameref
declare -A PLUGIN_SETUP_FUNCTIONS=(
  [keycloak]="deploy_keycloak create_users_and_groups_keycloak register_keycloak_client config_secrets_for_keycloak_plugins apply_keycloak_egress_policy apply_keycloak_labels"
  [kubernetes]="apply_kubernetes_plugin_rbac"
  [bulk-import]=":"
  [intelligent-assistant]="setup_intelligent_assistant"
  [orchestrator]=":"
  [scorecard]="configure_scorecard_credentials"
  [rbac]="apply_rbac_policies"
  [lighthouse]="deploy_lighthouse config_secrets_for_lighthouse_plugins apply_lighthouse_labels run_lighthouse_initial_scan"
)

# Plugin name -> teardown functions. Infrastructure teardown is explicit: a
# regular instance teardown must not remove shared resources such as Keycloak.
# shellcheck disable=SC2034 # used indirectly through a nameref
declare -A PLUGIN_TEARDOWN_FUNCTIONS=(
  [keycloak]="uninstall_keycloak_infra"
  [kubernetes]="remove_kubernetes_plugin_rbac"
  [lighthouse]="uninstall_lighthouse"
)

_execute_plugin_functions() {
  local function_map_name="$1"
  declare -n function_map="$function_map_name"
  local -A current_step_index
  local all_complete=false category functions step step_index

  if [[ ${#PLUGIN_LIST[@]} -eq 0 ]]; then
    echo "No plugins requiring cluster resources selected."
    return 0
  fi

  for category in "${PLUGIN_LIST[@]}"; do
    current_step_index["$category"]=0
  done

  while [[ "$all_complete" == "false" ]]; do
    all_complete=true
    for category in "${PLUGIN_LIST[@]}"; do
      functions="${function_map[$category]:-}"
      [[ -n "$functions" ]] || continue
      local -a steps
      read -ra steps <<< "$functions"
      step_index=${current_step_index[$category]}
      if [[ $step_index -lt ${#steps[@]} ]]; then
        step="${steps[$step_index]}"
        if [[ "$step" != ":" ]]; then
          echo ""
          echo "[$category] ${step}"
          "$step" || return 1
        fi
        current_step_index["$category"]=$((step_index + 1))
        all_complete=false
      fi
    done
  done
}

main() {
  local spec="${1:-}"

  echo ""
  echo "=============================================="
  echo "Plugin configuration"
  echo "=============================================="

  if [[ "${TEARDOWN:-false}" == "true" ]]; then
    # Only explicitly named plugins are torn down; "all" leaves the shared
    # Keycloak and other always-on infrastructure alone.
    resolve_plugins "$spec" --explicit-only
  else
    resolve_plugins "$spec"
  fi

  echo "Selected plugins: ${PLUGINS_RESOLVED:-none}"

  if [[ "${TEARDOWN:-false}" == "true" ]]; then
    _execute_plugin_functions PLUGIN_TEARDOWN_FUNCTIONS
  else
    _execute_plugin_functions PLUGIN_SETUP_FUNCTIONS
  fi

  echo ""
  echo "Plugin configuration complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
