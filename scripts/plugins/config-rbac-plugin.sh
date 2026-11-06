#!/usr/bin/env bash

# =============================================================================
# config-rbac-plugin.sh — policies used by the RBAC permission framework
# =============================================================================

apply_rbac_policies() {
  echo "Applying RBAC policies..."
  oc apply -f "${DEPLOY_ROOT}/resources/rbac/rbac-policies.yaml" \
    --namespace="${NAMESPACE}"
  echo "RBAC policies applied!"
}
