#!/usr/bin/env bash

# =============================================================================
# config-kubernetes-plugin.sh — read access for the Kubernetes/Topology plugins
#
# The plugins authenticate with the namespace's default service account, so it
# needs cluster-wide read access to pods, deployments, services and routes.
# =============================================================================

apply_kubernetes_plugin_rbac() {
  echo "Applying Kubernetes plugin RBAC..."

  local binding_name="rhdh-kubernetes-plugin-${NAMESPACE}"
  if oc get clusterrolebinding "${binding_name}" &>/dev/null; then
    echo "  ClusterRoleBinding ${binding_name} already exists — skipping."
    return 0
  fi

  oc create clusterrolebinding "${binding_name}" \
    --clusterrole=view \
    --serviceaccount="${NAMESPACE}:default"
  echo "  Created ClusterRoleBinding: ${binding_name}"
}

remove_kubernetes_plugin_rbac() {
  oc delete clusterrolebinding "rhdh-kubernetes-plugin-${NAMESPACE}" 2>/dev/null || true
}
