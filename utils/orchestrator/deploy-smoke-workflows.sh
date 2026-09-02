#!/bin/bash
#
# Deploy OSL smoke SonataFlow workloads into a namespace.
# Usage: deploy-smoke-workflows.sh <namespace> [greeting] [failswitch] [token-propagation]
# Default workflows: greeting failswitch token-propagation
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/utils/shell/common.sh"

ns="${1:-}"
[[ -n "$ns" ]] || die "namespace required"
shift || true

if [[ $# -eq 0 ]]; then
    set -- greeting failswitch token-propagation
fi

WORKFLOW_REPO="${SERVERLESS_WORKFLOWS_REPO:-https://github.com/rhdhorchestrator/serverless-workflows.git}"
WORKFLOW_REPO_REF="${SERVERLESS_WORKFLOWS_REF:-daeeee8dec16beab6d96a81774ef500081a2c2b0}"
DEMO_WORKFLOW_REPO="${ORCHESTRATOR_DEMO_REPO:-https://github.com/rhdhorchestrator/orchestrator-demo.git}"
DEMO_WORKFLOW_REF="${ORCHESTRATOR_DEMO_REF:-c6e59bab65bd584ede5fde7610bbc6187e70206c}"
SAMPLE_SERVER_IMAGE="${SAMPLE_SERVER_IMAGE:-quay.io/orchestrator/sample-server@sha256:67e694c65bdff0b256590ac32aaad1eeb2045ffbe6923b140d4e022acf8c8993}"
TOKEN_PROPAGATION_IMAGE="${TOKEN_PROPAGATION_IMAGE:-quay.io/orchestrator/demo-token-propagation@sha256:8b35f7aeafde48deed2700ab9bb247f77d1322d0a3c26005b51aaac782d55302}"

want_greeting=false
want_failswitch=false
want_token=false
for name in "$@"; do
    case "$name" in
        greeting) want_greeting=true ;;
        failswitch) want_failswitch=true ;;
        token-propagation) want_token=true ;;
        *) die "unknown smoke workflow: $name" ;;
    esac
done

csv_mm_for_package() {
    local package="$1"
    local version
    version="$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r --arg p "$package" '
        .items[]
        | select(.status.phase == "Succeeded")
        | select((.spec.name == $p) or ((.metadata.name // "") | startswith($p + ".")))
        | .spec.version // empty
    ' | head -n 1)"
    echo "$version" | grep -oE '^[0-9]+\.[0-9]+' || true
}

workflow_osl_image_tag() {
    local os_mm osl_mm chosen
    os_mm="$(csv_mm_for_package serverless-operator)"
    osl_mm="$(csv_mm_for_package logic-operator)"
    if [[ -n "$os_mm" && -n "$osl_mm" ]]; then
        if [[ "$(printf '%s\n%s\n' "$os_mm" "$osl_mm" | sort -V | head -n 1)" == "$os_mm" ]]; then
            chosen="$os_mm"
        else
            chosen="$osl_mm"
        fi
    else
        chosen="${os_mm:-${osl_mm:-1.37}}"
    fi
    echo "${chosen//./_}"
}

patch_smoke_workflow() {
    local name="$1" tag="${2:-}" image
    case "$name" in
        greeting)   image="quay.io/orchestrator/serverless-workflow-greeting:osl_${tag}" ;;
        failswitch) image="quay.io/orchestrator/fail-switch:osl_${tag}" ;;
        token-propagation) image="${TOKEN_PROPAGATION_IMAGE}" ;;
        *) die "unknown smoke workflow: $name" ;;
    esac
    oc -n "$ns" patch sonataflow "$name" --type merge -p "{
      \"spec\": {
        \"persistence\": {
          \"dbMigrationStrategy\": \"job\",
          \"postgresql\": {
            \"secretRef\": {
              \"name\": \"backstage-psql-secret\",
              \"userKey\": \"POSTGRES_USER\",
              \"passwordKey\": \"POSTGRES_PASSWORD\"
            },
            \"serviceRef\": {
              \"name\": \"backstage-psql\",
              \"namespace\": \"${ns}\",
              \"databaseName\": \"backstage_plugin_orchestrator\",
              \"databaseSchema\": \"${name}\"
            }
          }
        },
        \"podTemplate\": {
          \"container\": {
            \"image\": \"${image}\",
            \"env\": [{\"name\": \"KOGITO_SERVICE_URL\", \"value\": \"http://${name}.${ns}.svc.cluster.local\"}]
          }
        }
      }
    }" >/dev/null
}

wait_named_workflows_ready() {
    local timeout_secs="$1"
    shift
    local -a names=("$@")
    local start elapsed ready name replicas
    start="$(date +%s)"
    while true; do
        ready=true
        for name in "${names[@]}"; do
            replicas="$(oc get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
            if [[ "$replicas" != "1" ]]; then
                ready=false
            fi
        done
        if [[ "$ready" == "true" ]]; then
            log "smoke workflows ready: ${names[*]}"
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= timeout_secs )); then
            die "timeout waiting for workflow deployments in $ns: ${names[*]}"
        fi
        sleep 10
    done
}

ensure_token_propagation_workflow() {
    local demo_dir manifests_dir props_cm specs_cm
    [[ -n "${KEYCLOAK_BASE_URL:-}" ]] || die "KEYCLOAK_BASE_URL is required for token-propagation smoke"
    log "deploying token-propagation workflow and sample-server"
    demo_dir="$(mktemp -d /tmp/osl-token-demo-XXXXXX)"
    git clone --depth 1 "$DEMO_WORKFLOW_REPO" "$demo_dir" >/dev/null
    git -C "$demo_dir" fetch --depth 1 origin "$DEMO_WORKFLOW_REF" >/dev/null
    git -C "$demo_dir" checkout --detach "$DEMO_WORKFLOW_REF" >/dev/null
    manifests_dir="${demo_dir}/09_token_propagation/manifests"
    props_cm="${manifests_dir}/01-configmap_token-propagation-props.yaml"
    specs_cm="${manifests_dir}/03-configmap_02-token-propagation-resources-specs.yaml"
    [[ -f "$props_cm" && -f "$specs_cm" ]] || die "token-propagation manifests missing in $DEMO_WORKFLOW_REPO"
    local kc_base realm client_id client_secret auth_server_url token_url sample_url
    kc_base="${KEYCLOAK_BASE_URL%/}"
    realm="${KEYCLOAK_REALM:-rhdh}"
    client_id="${KEYCLOAK_CLIENT_ID:-rhdh-client}"
    client_secret="${KEYCLOAK_CLIENT_SECRET:-rhdh-client-secret}"
    auth_server_url="${kc_base}/realms/${realm}"
    token_url="${auth_server_url}/protocol/openid-connect/token"
    sample_url="http://sample-server-service.${ns}:8080"
    sed -i \
        -e "s|http://example-kc-service.keycloak:8080/realms/quarkus|${auth_server_url}|g" \
        -e "s|client-id=quarkus-app|client-id=${client_id}|g" \
        -e "s|client-secret=lVGSvdaoDUem7lqeAnqXn1F92dCPbQea|client-secret=${client_secret}|g" \
        -e "s|http://sample-server-service.rhdh-operator|${sample_url}|g" \
        "$props_cm"
    sed -i \
        -e "s|http://example-kc-service.keycloak:8080/realms/quarkus/protocol/openid-connect/token|${token_url}|g" \
        "$specs_cm"
    oc apply -n "$ns" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-server
  labels:
    app: sample-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-server
  template:
    metadata:
      labels:
        app: sample-server
    spec:
      containers:
        - name: sample-server
          image: ${SAMPLE_SERVER_IMAGE}
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: sample-server-service
  labels:
    app: sample-server
spec:
  selector:
    app: sample-server
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
EOF
    oc wait deployment/sample-server -n "$ns" --for=condition=Available --timeout=120s
    oc apply -n "$ns" -f "$manifests_dir"
    patch_smoke_workflow token-propagation
    rm -rf "$demo_dir"
}

tag="$(workflow_osl_image_tag)"
log "deploying smoke workflows in ${ns} (image tag osl_${tag}): $*"

ready_names=()
if [[ "$want_greeting" == "true" || "$want_failswitch" == "true" ]]; then
    workflow_dir="$(mktemp -d /tmp/osl-workflows-XXXXXX)"
    git clone --depth 1 "$WORKFLOW_REPO" "$workflow_dir" >/dev/null
    git -C "$workflow_dir" fetch --depth 1 origin "$WORKFLOW_REPO_REF" >/dev/null
    git -C "$workflow_dir" checkout --detach "$WORKFLOW_REPO_REF" >/dev/null
    if [[ "$want_greeting" == "true" ]]; then
        oc apply -n "$ns" -f "${workflow_dir}/workflows/greeting/manifests"
        patch_smoke_workflow greeting "$tag"
        ready_names+=(greeting)
    fi
    if [[ "$want_failswitch" == "true" ]]; then
        oc apply -n "$ns" -f "${workflow_dir}/workflows/fail-switch/src/main/resources/manifests"
        patch_smoke_workflow failswitch "$tag"
        ready_names+=(failswitch)
    fi
    rm -rf "$workflow_dir"
fi

if [[ "$want_token" == "true" ]]; then
    ensure_token_propagation_workflow
    ready_names+=(token-propagation)
fi

wait_named_workflows_ready 600 "${ready_names[@]}"
oc rollout restart "deploy/sonataflow-platform-data-index-service" -n "$ns" >/dev/null 2>&1 || true
oc rollout status "deploy/sonataflow-platform-data-index-service" -n "$ns" --timeout=180s
