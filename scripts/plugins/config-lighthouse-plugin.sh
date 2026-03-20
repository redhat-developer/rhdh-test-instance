#!/bin/bash

# =============================================================================
# Lighthouse Plugin Configuration
# =============================================================================
# This script deploys and configures resources required for the Lighthouse
# plugin. It deploys a self-hosted lighthouse-audit-service instance backed
# by an in-cluster PostgreSQL database, runs an initial scan against the RHDH
# instance, and registers demo catalog entities.
#
# Functions are structured for efficient round-robin execution:
#   1. deploy_lighthouse                     — Deploy the audit service + Postgres (quick)
#   2. config_secrets_for_lighthouse_plugins — Wait for readiness, then inject URL
#                                              into rhdh-secrets and plugin overlay ConfigMap
#   3. apply_lighthouse_labels               — Label resources for the K8s plugin
#   4. run_lighthouse_initial_scan           — Submit initial scan using RHDH_BASE_URL
#
# Readiness polling is embedded at the top of config_secrets_for_lighthouse_plugins
# rather than as a standalone step. This keeps the round-robin loop doing useful
# work on other plugins instead of burning a full turn on a pure wait.
#
# RHDH_BASE_URL is exported by deploy.sh before any plugin scripts run.
# =============================================================================

# =============================================================================
# Step 1: Deploy the Lighthouse audit service (quick action)
# =============================================================================
deploy_lighthouse() {
  echo "Deploying Lighthouse audit service..."

  # Generate Lighthouse DB credentials only on first run.
  if oc get secret lighthouse-credentials --namespace="${NAMESPACE}" &>/dev/null; then
    echo "lighthouse-credentials already exists — skipping generation."
  else
    echo "Generating lighthouse-credentials Secret..."
    local lh_db_password
    lh_db_password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

    oc create secret generic lighthouse-credentials \
      --from-literal=password="${lh_db_password}" \
      --namespace="${NAMESPACE}"
  fi

  oc apply -f "$PWD/resources/lighthouse/lighthouse-deployment.yaml" \
    --namespace="${NAMESPACE}"
  echo "Lighthouse deployment applied!"
}

# =============================================================================
# Step 1b: Run initial scan against the RHDH instance.
# =============================================================================
run_lighthouse_initial_scan() {
  if [[ "${POPULATE_DEMO_DATA:-true}" == "false" ]]; then
    echo "Demo data disabled — skipping initial Lighthouse scan."
    return 0
  fi

  local RHDH_URL="${RHDH_BASE_URL:-}"
  if [[ -z "${RHDH_URL}" ]]; then
    echo "Warning: RHDH_BASE_URL not set — skipping initial scan."
    return 0
  fi

  echo "Running initial Lighthouse scan against: ${RHDH_URL}"

  # Delete any leftover scan job from a previous run so oc apply succeeds.
  oc delete job lighthouse-initial-scan \
    --namespace="${NAMESPACE}" 2>/dev/null || true

  LIGHTHOUSE_SVC="http://lighthouse.${NAMESPACE}.svc.cluster.local:3003"
  sed \
    -e "s|<RHDH_URL>|${RHDH_URL}|g" \
    -e "s|<LIGHTHOUSE_SVC>|${LIGHTHOUSE_SVC}|g" \
    "$PWD/resources/lighthouse/lighthouse-scan-job.yaml" \
    | oc apply -f - --namespace="${NAMESPACE}"

  echo "Lighthouse scan job submitted — it will complete in the background once RHDH is up."
}

# =============================================================================
# Step 2: Configure the plugin overlay (inject the in-cluster service URL)
#         (waits for Lighthouse readiness internally before proceeding)
# =============================================================================
config_secrets_for_lighthouse_plugins() {
  echo "Configuring Lighthouse plugin overlay..."

  # ---- Wait for Lighthouse deployment ----
  echo "Waiting for Lighthouse audit service to become ready..."
  SECONDS=0
  while true; do
    local ready
    ready=$(oc get deployment lighthouse \
      --namespace="${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready}" == "1" ]] && echo "Lighthouse audit service is ready!" && break
    if [[ $SECONDS -ge ${TIMEOUT:-300} ]]; then
      echo "Warning: Timeout waiting for Lighthouse to become ready — continuing anyway."
      break
    fi
    echo "  Lighthouse not ready yet (readyReplicas=${ready:-0}). Retrying in ${INTERVAL:-15}s..."
    sleep "${INTERVAL:-15}"
  done

  local lighthouse_route_host
  lighthouse_route_host=$(oc get route lighthouse \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  # Route through the RHDH backend proxy so plain browser fetch() calls never
  # hit the Lighthouse service directly (avoids browser TLS cert trust issues).
  # The proxy target uses the in-cluster HTTP service — no TLS needed there.
  # LIGHTHOUSE_SVC_URL is also used by the initial scan job.
  export LIGHTHOUSE_SVC_URL="http://lighthouse.${NAMESPACE}.svc.cluster.local:3003"
  export LIGHTHOUSE_URL="${RHDH_BASE_URL}/api/proxy/lighthouse"

  if [[ -z "${lighthouse_route_host}" ]]; then
    echo "Warning: Could not resolve Lighthouse route host."
  fi
  echo "Note: LIGHTHOUSE_URL set to RHDH proxy path; LIGHTHOUSE_SVC_URL set to in-cluster service."

  oc patch secret rhdh-secrets -n "${NAMESPACE}" \
    --type=merge -p "{\"stringData\":{\"LIGHTHOUSE_URL\":\"${LIGHTHOUSE_URL}\",\"LIGHTHOUSE_SVC_URL\":\"${LIGHTHOUSE_SVC_URL}\"}}"

  _append_plugin_dynamic_config "${PWD}/resources/lighthouse/dynamic-plugins.yaml" "Lighthouse"

  echo "Lighthouse plugin overlay applied!"
}

# =============================================================================
# Step 3: Apply backstage.io/kubernetes-id labels
# =============================================================================
apply_lighthouse_labels() {
  echo "Applying Kubernetes labels for Lighthouse resources..."

  declare -A patterns=(
    ["lighthouse"]="backstage.io/kubernetes-id=lighthouse-instance"
  )

  resource_types=("pods" "deployments" "replicasets" "services" "routes" "statefulsets")

  for resource in "${resource_types[@]}"; do
    for pattern in "${!patterns[@]}"; do
      label="${patterns[$pattern]}"
      oc get "$resource" -n "${NAMESPACE}" --no-headers \
        -o custom-columns=":metadata.name" 2>/dev/null \
        | grep "$pattern" \
        | xargs -I {} oc label "$resource" {} "$label" --overwrite \
            -n "${NAMESPACE}" 2>/dev/null || true
    done
  done

  echo "Labels applied successfully!"
}

# =============================================================================
# Teardown
# =============================================================================
uninstall_lighthouse() {
  echo "Uninstalling Lighthouse resources..."

  # Catalog entity ConfigMaps are owned by setup-resources.sh and cleaned up
  # by teardown_resources. Only Lighthouse-specific infrastructure is removed
  # here.
  oc delete job lighthouse-initial-scan \
    --namespace="${NAMESPACE}" 2>/dev/null || true
  oc delete -f "$PWD/resources/lighthouse/lighthouse-deployment.yaml" \
    --namespace="${NAMESPACE}" 2>/dev/null || true
  oc delete secret lighthouse-credentials \
    --namespace="${NAMESPACE}" 2>/dev/null || true

  echo "Lighthouse uninstalled!"
}

# =============================================================================
# Main (standalone execution)
# =============================================================================
main() {
  if [[ ! -f "${PWD}/.env" ]]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
  fi
  source "${PWD}/.env"

  echo "=============================================="
  echo "Configuring Lighthouse Plugin"
  echo "=============================================="

  deploy_lighthouse
  config_secrets_for_lighthouse_plugins
  apply_lighthouse_labels
  run_lighthouse_initial_scan

  echo ""
  echo "=============================================="
  echo "Lighthouse configuration complete!"
  echo "=============================================="

  exit "${OVERALL_RESULT:-0}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
