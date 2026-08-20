#!/bin/bash
#
# One-command setup of RHDH + orchestrator for overlays e2e.
# Deploys Keycloak, installs orchestrator prerequisites, deploys RHDH via Helm,
# and verifies the shared existing-RHDH substrate contract.
#
# Usage:
#   ./setup-orchestrator.sh <version> [--namespace <ns>] [--prepare-internal-osl <release>]
#
# Examples:
#   ./setup-orchestrator.sh 1.9
#   ./setup-orchestrator.sh 1.9-200-CI
#   ./setup-orchestrator.sh next --namespace rhdh-test
#   ./setup-orchestrator.sh 1.9 --prepare-internal-osl 1.39.0.CR1
#   ./setup-orchestrator.sh 1.10 --prepare-internal-osl 1.39.0.CR1
#
# Options:
#   --namespace <ns>    Target namespace (default: orchestrator)
#   --prepare-internal-osl <release>
#                       Mirror pre-release OSL images into the OpenShift internal
#                       registry, generate a rewritten internal logic-only catalog,
#                       create CatalogSource, and write .env.osl with OSL_* exports
#                       for this run.
# Prerequisites:
#   - oc logged in to the target cluster
#   - helm, git, jq available on PATH
#   - .env file configured (or --prepare-internal-osl to generate .env.osl)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the parent workspace directory: the main repo root's parent, even from a worktree.
_git_common="$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null)"
_main_repo_root="$(cd "$SCRIPT_DIR" && cd "$_git_common/.." 2>/dev/null && pwd)"
WORKSPACE_DIR="$(dirname "${_main_repo_root:-$SCRIPT_DIR}")"
RHDH_E2E_TEST_UTILS_DIR="${RHDH_E2E_TEST_UTILS_DIR:-${WORKSPACE_DIR}/rhdh-e2e-test-utils}"
unset _git_common _main_repo_root
SHARED_INSTALL_SCRIPT="${RHDH_E2E_TEST_UTILS_DIR}/dist/deployment/orchestrator/install-orchestrator.sh"
LOCAL_VERIFY_EXISTING_RHDH_SCRIPT="${SCRIPT_DIR}/utils/orchestrator/verify-existing-rhdh.sh"
SHARED_VERIFY_EXISTING_RHDH_SCRIPT="${SHARED_VERIFY_EXISTING_RHDH_SCRIPT:-$LOCAL_VERIFY_EXISTING_RHDH_SCRIPT}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-rhdh-keycloak}"

# ── Argument parsing ─────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--namespace <ns>] [--prepare-internal-osl <release>]"
    echo ""
    echo "Examples:"
    echo "  $0 1.9              # latest 1.9.x chart"
    echo "  $0 1.9-200-CI       # specific CI build"
    echo "  $0 next             # latest development build"
    echo "  $0 1.9 --prepare-internal-osl 1.39.0.CR1"
    echo "  $0 1.10 --prepare-internal-osl 1.39.0.CR1"
    exit 1
fi

version="$1"
shift

namespace="orchestrator"
prepare_internal_osl_release=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            namespace="$2"
            shift 2
            ;;
        --prepare-internal-osl)
            prepare_internal_osl_release="${2:-}"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1"
            exit 1
            ;;
    esac
done

cd "$SCRIPT_DIR"

# ── Validate inputs ──────────────────────────────────────────────────────────

if ! oc whoami &>/dev/null; then
    echo "Error: Cannot connect to OpenShift cluster. Is CRC running and are you logged in?"
    echo "  Try: crc start && oc login -u kubeadmin https://api.crc.testing:6443"
    exit 1
fi

if [[ ! "$namespace" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "Error: Invalid namespace name: '$namespace' (must be lowercase alphanumeric/hyphens, 1-63 chars)"
    exit 1
fi

assert_empty_baseline() {
    local ns="$1"
    local keycloak_ns="$2"
    local found=0

    if [[ "${SKIP_EMPTY_BASELINE:-}" == "1" ]]; then
        echo "==> Skipping empty-baseline check (SKIP_EMPTY_BASELINE=1)."
        return 0
    fi

    echo "==> Verifying clean baseline (no existing RHDH/OSL components)..."

    if helm status redhat-developer-hub -n "$ns" >/dev/null 2>&1; then
        echo "Error: Existing Helm release 'redhat-developer-hub' found in namespace '$ns'."
        found=1
    fi

    if oc get deployment redhat-developer-hub -n "$ns" >/dev/null 2>&1; then
        echo "Error: Existing deployment/redhat-developer-hub found in namespace '$ns'."
        found=1
    fi

    if oc get sonataflowplatform -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        echo "Error: Existing SonataFlowPlatform resources found in namespace '$ns'."
        found=1
    fi

    if oc get sonataflow -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        echo "Error: Existing SonataFlow workflow resources found in namespace '$ns'."
        found=1
    fi

    if oc get subscription serverless-operator -n openshift-operators >/dev/null 2>&1; then
        echo "Error: Existing Subscription/serverless-operator found in openshift-operators."
        found=1
    fi

    if oc get subscription logic-operator -n openshift-operators >/dev/null 2>&1; then
        echo "Error: Existing Subscription/logic-operator found in openshift-operators."
        found=1
    fi

    if oc get catalogsource osl-custom-catalog -n openshift-marketplace >/dev/null 2>&1; then
        if [[ -n "${OSL_CATALOG_SOURCE:-}" ]]; then
            echo "==> CatalogSource/osl-custom-catalog present from prepare-osl; allowing it."
        else
            echo "Error: Existing CatalogSource/osl-custom-catalog found in openshift-marketplace."
            found=1
        fi
    fi

    if oc get statefulset keycloak -n "$keycloak_ns" >/dev/null 2>&1 || \
       oc get deployment keycloak -n "$keycloak_ns" >/dev/null 2>&1; then
        echo "Error: Existing Keycloak deployment found in namespace '$keycloak_ns'."
        found=1
    fi

    if [[ $found -ne 0 ]]; then
        echo ""
        echo "Cluster is not clean. Run cleanup first, e.g.:"
        echo "  ./cleanup.sh --namespace ${ns} --include-operators --delete-namespace"
        echo "Then rerun setup."
        exit 1
    fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "==> $*"; }
log_debug() { echo "[DEBUG $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
phase_checkpoint() { echo "[CHECKPOINT] $*"; }

emit_diag_hints() {
    local ns="$1"
    echo "Diagnostics to run:"
    echo "  oc get pods -n ${ns}"
    echo "  oc get events -n ${ns} --sort-by=.lastTimestamp | tail -n 30"
    echo "  oc describe deployment redhat-developer-hub -n ${ns}"
    echo "  oc get csv -n openshift-operators"
}

ensure_shared_scripts() {
    if [[ ! -x "$SHARED_INSTALL_SCRIPT" ]]; then
        if [[ -f "${RHDH_E2E_TEST_UTILS_DIR}/package.json" ]]; then
            log "Building shared rhdh-e2e-test-utils artifacts..."
            (cd "$RHDH_E2E_TEST_UTILS_DIR" && yarn build >/dev/null)
        fi
    fi
    if [[ ! -x "$SHARED_INSTALL_SCRIPT" ]]; then
        echo "Error: Shared install script not found: $SHARED_INSTALL_SCRIPT"
        exit 1
    fi
    if [[ ! -x "$SHARED_VERIFY_EXISTING_RHDH_SCRIPT" ]]; then
        echo "Error: Existing-RHDH verification script not found or not executable: $SHARED_VERIFY_EXISTING_RHDH_SCRIPT"
        echo "Hint: set SHARED_VERIFY_EXISTING_RHDH_SCRIPT to override, or use the local default script."
        exit 1
    fi
    log "Using existing-RHDH verification script: $SHARED_VERIFY_EXISTING_RHDH_SCRIPT"
}

run_shared_orchestrator_install() {
    local args=("$namespace")

    ensure_shared_scripts

    if [[ -n "${OSL_CATALOG_SOURCE:-}" ]]; then
        args+=(--logic-operator-source "${OSL_CATALOG_SOURCE}")
        args+=(--logic-operator-source-namespace "openshift-marketplace")
    fi
    [[ -n "${OSL_LOGIC_PACKAGE:-}" ]] && args+=(--logic-operator-package "${OSL_LOGIC_PACKAGE}")
    [[ -n "${OSL_LOGIC_CHANNEL:-}" ]] && args+=(--logic-operator-channel "${OSL_LOGIC_CHANNEL}")
    [[ -n "${OSL_LOGIC_CSV:-}" ]] && args+=(--logic-operator-starting-csv "${OSL_LOGIC_CSV}")
    [[ -n "${OSL_SERVERLESS_PACKAGE:-}" ]] && args+=(--serverless-operator-package "${OSL_SERVERLESS_PACKAGE}")
    [[ -n "${OSL_SERVERLESS_CHANNEL:-}" ]] && args+=(--serverless-operator-channel "${OSL_SERVERLESS_CHANNEL}")
    [[ -n "${OSL_SERVERLESS_SOURCE:-}" ]] && args+=(--serverless-operator-source "${OSL_SERVERLESS_SOURCE}")
    [[ -n "${OSL_SERVERLESS_SOURCE_NAMESPACE:-}" ]] && args+=(--serverless-operator-source-namespace "${OSL_SERVERLESS_SOURCE_NAMESPACE}")

    log_debug "Shared orchestrator install args: ${args[*]}"
    bash "$SHARED_INSTALL_SCRIPT" "${args[@]}"
    phase_checkpoint "shared-orchestrator-installed"
}

extract_major_minor() {
    local version="$1"
    echo "$version" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
}

get_subscription_field() {
    local name="$1" field="$2"
    oc get subscriptions.operators.coreos.com "$name" -n openshift-operators -o "jsonpath={.spec.${field}}" 2>/dev/null || true
}

get_operator_csv_name() {
    local package="$1"
    local csv_name
    csv_name="$(oc get csv -n openshift-operators -l "operators.coreos.com/${package}.openshift-operators" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$csv_name" && "$package" == "logic-operator" ]]; then
        csv_name="$(oc get csv -n openshift-operators -l "operators.coreos.com/logic-operator-rhel8.openshift-operators" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    echo "$csv_name"
}

get_operator_csv_version() {
    local package="$1"
    local csv_name
    csv_name="$(get_operator_csv_name "$package")"
    [[ -z "$csv_name" ]] && { echo ""; return 0; }
    oc get csv "$csv_name" -n openshift-operators -o jsonpath='{.spec.version}' 2>/dev/null || true
}

assert_operator_configuration() {
    local package="$1" sub_name="$2" expected_channel="$3" expected_source="$4" expected_source_ns="$5" expected_starting_csv="$6"
    local actual_channel actual_source actual_source_ns actual_starting_csv
    actual_channel="$(get_subscription_field "$sub_name" channel)"
    actual_source="$(get_subscription_field "$sub_name" source)"
    actual_source_ns="$(get_subscription_field "$sub_name" sourceNamespace)"
    actual_starting_csv="$(get_subscription_field "$sub_name" startingCSV)"

    if [[ -n "$expected_channel" && "$actual_channel" != "$expected_channel" ]]; then
        echo "Error: ${package} channel mismatch. expected='${expected_channel}' actual='${actual_channel}'"
        exit 1
    fi
    if [[ -n "$expected_source" && "$actual_source" != "$expected_source" ]]; then
        echo "Error: ${package} source mismatch. expected='${expected_source}' actual='${actual_source}'"
        exit 1
    fi
    if [[ -n "$expected_source_ns" && "$actual_source_ns" != "$expected_source_ns" ]]; then
        echo "Error: ${package} source namespace mismatch. expected='${expected_source_ns}' actual='${actual_source_ns}'"
        exit 1
    fi
    if [[ -n "$expected_starting_csv" && "$actual_starting_csv" != "$expected_starting_csv" ]]; then
        echo "Error: ${package} startingCSV mismatch. expected='${expected_starting_csv}' actual='${actual_starting_csv}'"
        exit 1
    fi
}

assert_pre_release_install_state() {
    local expected_logic_source="${OSL_CATALOG_SOURCE:-${OSL_LOGIC_SOURCE:-}}"
    local expected_logic_source_ns="${OSL_LOGIC_SOURCE_NAMESPACE:-openshift-marketplace}"
    local expected_logic_channel="${OSL_LOGIC_CHANNEL:-stable}"
    local expected_logic_csv="${OSL_LOGIC_CSV:-}"

    local expected_serverless_source="${OSL_SERVERLESS_SOURCE:-redhat-operators}"
    local expected_serverless_source_ns="${OSL_SERVERLESS_SOURCE_NAMESPACE:-openshift-marketplace}"
    local expected_serverless_channel="${OSL_SERVERLESS_CHANNEL:-stable}"

    log "Asserting installed operator subscriptions and versions..."
    assert_operator_configuration "logic-operator" "logic-operator" "$expected_logic_channel" "$expected_logic_source" "$expected_logic_source_ns" "$expected_logic_csv"
    assert_operator_configuration "serverless-operator" "serverless-operator" "$expected_serverless_channel" "$expected_serverless_source" "$expected_serverless_source_ns" ""

    local logic_csv logic_version serverless_version logic_mm serverless_mm
    logic_csv="$(get_operator_csv_name "logic-operator")"
    logic_version="$(get_operator_csv_version "logic-operator")"
    serverless_version="$(get_operator_csv_version "serverless-operator")"

    if [[ -z "$logic_csv" || -z "$logic_version" ]]; then
        echo "Error: Unable to resolve installed logic-operator CSV/version."
        exit 1
    fi

    if [[ -n "${OSL_VERSION:-}" ]]; then
        local osl_marker
        osl_marker="$(echo "${OSL_VERSION}" | tr '[:upper:]' '[:lower:]')"
        local csv_lc version_lc
        csv_lc="$(echo "${logic_csv}" | tr '[:upper:]' '[:lower:]')"
        version_lc="$(echo "${logic_version}" | tr '[:upper:]' '[:lower:]')"
        if [[ "$osl_marker" == *"cr"* || "$osl_marker" == *"rc"* ]]; then
            # Some pre-release catalogs publish a GA-looking CSV/version while still being
            # sourced from a pre-release catalog and pinned startingCSV; accept that case.
            if [[ "$csv_lc" != *"cr"* && "$csv_lc" != *"rc"* && "$version_lc" != *"cr"* && "$version_lc" != *"rc"* ]]; then
                if [[ -n "${expected_logic_csv:-}" && "$logic_csv" == "$expected_logic_csv" ]]; then
                    log "Pre-release marker not present in CSV/version; accepted because installed CSV matches expected startingCSV (${expected_logic_csv})."
                else
                    echo "Error: Expected pre-release OSL marker in installed logic-operator CSV/version. csv='${logic_csv}' version='${logic_version}'"
                    exit 1
                fi
            fi
        fi
    fi

    logic_mm="$(extract_major_minor "$logic_version")"
    serverless_mm="$(extract_major_minor "$serverless_version")"
    if [[ -n "$logic_mm" && -n "$serverless_mm" && "$logic_mm" != "$serverless_mm" ]]; then
        if [[ "${ALLOW_OSL_SERVERLESS_VERSION_SKEW:-0}" != "1" ]]; then
            echo "Error: Serverless/Logic major.minor mismatch (serverless=${serverless_mm}, logic=${logic_mm}). Set ALLOW_OSL_SERVERLESS_VERSION_SKEW=1 to override."
            exit 1
        fi
        echo "Warning: Serverless/Logic major.minor mismatch allowed by ALLOW_OSL_SERVERLESS_VERSION_SKEW=1 (serverless=${serverless_mm}, logic=${logic_mm})."
    fi

    log "Installed logic-operator CSV: ${logic_csv} (version=${logic_version})"
    log "Installed serverless-operator version: ${serverless_version:-unknown}"
    phase_checkpoint "operator-configuration-asserted"
}

prepare_keycloak() {
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/utils/keycloak/keycloak-deploy.sh" "$KEYCLOAK_NAMESPACE"
}

sync_keycloak_runtime_env() {
    local keycloak_host keycloak_proto
    keycloak_host="$(oc get route keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [[ -z "$keycloak_host" ]]; then
        echo "Error: could not resolve Keycloak route in namespace '$KEYCLOAK_NAMESPACE'."
        exit 1
    fi

    if [[ -z "${KEYCLOAK_BASE_URL:-}" ]]; then
        keycloak_proto="http"
        if oc get route keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
            keycloak_proto="https"
        fi
        export KEYCLOAK_BASE_URL="${keycloak_proto}://${keycloak_host}"
    fi
    export KEYCLOAK_METADATA_URL="${KEYCLOAK_BASE_URL}/realms/rhdh"
    export KEYCLOAK_REALM="${KEYCLOAK_REALM:-rhdh}"
    export KEYCLOAK_LOGIN_REALM="${KEYCLOAK_LOGIN_REALM:-${KEYCLOAK_REALM}}"
    export KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-rhdh-client}"
    export KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-rhdh-client-secret}"

    if [[ -z "${KEYCLOAK_LOGIN_REALM}" ]]; then
        echo "Error: KEYCLOAK_LOGIN_REALM resolved to empty value."
        exit 1
    fi
}

verify_shared_existing_rhdh_contract() {
    log "Verifying shared existing-RHDH contract in ${namespace}..."
    bash "$SHARED_VERIFY_EXISTING_RHDH_SCRIPT" "$namespace" --require-keycloak
    phase_checkpoint "shared-existing-rhdh-verified"
}

log_debug "Entrypoint args: version=${version}, namespace=${namespace}, prepareInternalOsl=${prepare_internal_osl_release:-none}"
phase_checkpoint "cluster-connectivity-validated"
if [[ -f "${SCRIPT_DIR}/.env.osl" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env.osl"
    log "Loaded existing .env.osl before baseline (OSL_CATALOG_SOURCE=${OSL_CATALOG_SOURCE:-unset})"
fi
assert_empty_baseline "$namespace" "$KEYCLOAK_NAMESPACE"

wait_for_rhdh_auth_and_orchestrator_ready() {
    local ns="$1"
    local timeout_secs="${2:-240}"
    local start_time
    start_time=$(date +%s)

    local rhdh_host
    rhdh_host="$(oc get route redhat-developer-hub -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [[ -z "$rhdh_host" ]]; then
        echo "Error: Could not resolve RHDH route in namespace '$ns'."
        return 1
    fi

    log "Waiting for RHDH auth/backend HTTP readiness..."
    while true; do
        local elapsed auth_status auth_location app_health orch_health
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_secs ]]; then
            echo "Error: Timed out waiting for auth/backend HTTP readiness after ${timeout_secs}s"
            echo "  Last auth status: ${auth_status:-unknown}"
            echo "  Last auth redirect: ${auth_location:-<empty>}"
            echo "  Last backend health: ${app_health:-unknown}"
            echo "  Last orchestrator health: ${orch_health:-unknown}"
            return 1
        fi

        auth_status=$(curl -sk -o /dev/null -w '%{http_code}' "https://${rhdh_host}/api/auth/oidc/start?env=production" || true)
        auth_location=$(curl -sk -D - -o /dev/null "https://${rhdh_host}/api/auth/oidc/start?env=production" | \
            awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2; exit}' | tr -d '\r')
        app_health=$(curl -sk -o /dev/null -w '%{http_code}' "https://${rhdh_host}/api/app/health" || true)
        orch_health=$(curl -sk -o /dev/null -w '%{http_code}' "https://${rhdh_host}/api/orchestrator/health" || true)

        if [[ "$app_health" == "200" && "$auth_status" == "302" && "$auth_location" =~ ^https:// && "$orch_health" == "200" ]]; then
            log "RHDH auth/backend/orchestrator readiness checks passed."
            return 0
        fi

        sleep 3
    done
}

run_post_setup_workflow_smoke() {
    local ns="$1"
    local run_smoke="${POST_SETUP_WORKFLOW_SMOKE:-1}"
    if [[ "$run_smoke" != "1" ]]; then
        log "Skipping post-setup workflow smoke (POST_SETUP_WORKFLOW_SMOKE=${run_smoke})."
        return 0
    fi

    local workflow_repo="${SERVERLESS_WORKFLOWS_REPO:-https://github.com/rhdhorchestrator/serverless-workflows.git}"
    local workflow_ref="${SERVERLESS_WORKFLOWS_REF:-daeeee8dec16beab6d96a81774ef500081a2c2b0}"
    local workflow_dir="/tmp/serverless-workflows-${RANDOM}-${RANDOM}"
    local greeting_manifest_dir="${workflow_dir}/workflows/greeting/manifests"

    log "Running post-setup workflow smoke in namespace ${ns}..."
    git clone --depth=1 "$workflow_repo" "$workflow_dir" >/dev/null 2>&1
    git -C "$workflow_dir" fetch --depth=1 origin "$workflow_ref" >/dev/null 2>&1
    git -C "$workflow_dir" checkout --detach "$workflow_ref" >/dev/null 2>&1

    oc apply -n "$ns" -f "$greeting_manifest_dir" >/dev/null
    oc patch sonataflow greeting -n "$ns" --type merge -p '{
      "spec": {
        "persistence": {
          "postgresql": {
            "secretRef": {
              "name": "backstage-psql-secret",
              "userKey": "POSTGRES_USER",
              "passwordKey": "POSTGRES_PASSWORD"
            },
            "serviceRef": {
              "name": "backstage-psql",
              "namespace": "'"$ns"'",
              "databaseName": "backstage_plugin_orchestrator"
            }
          }
        }
      }
    }' >/dev/null

    oc rollout restart deployment/greeting -n "$ns" >/dev/null 2>&1 || true
    oc rollout status deployment/greeting -n "$ns" --timeout=600s >/dev/null
    oc exec -n "$ns" deploy/sonataflow-platform-data-index-service -- \
        curl -sf --max-time 5 "http://localhost:8080/q/health/ready" >/dev/null

    local orchestrator_host orch_health
    orchestrator_host="$(oc get route redhat-developer-hub -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    orch_health="$(curl -sk -o /dev/null -w '%{http_code}' "https://${orchestrator_host}/api/orchestrator/health" || true)"
    if [[ "$orch_health" != "200" ]]; then
        echo "Error: Post-smoke orchestrator health check failed (HTTP ${orch_health})."
        rm -rf "$workflow_dir"
        exit 1
    fi

    rm -rf "$workflow_dir"
    phase_checkpoint "post-setup-workflow-smoke-passed"
}

# ── Internal pre-release OSL preparation ──────────────────────────────────────

if [[ -n "$prepare_internal_osl_release" ]]; then
    log "Preparing internal OSL mirror for release ${prepare_internal_osl_release}..."
    "${SCRIPT_DIR}/prepare-osl-internal.sh" --release "${prepare_internal_osl_release}" --namespace "${namespace}"
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env.osl"
    log "Loaded OSL_IIB_IMAGE=${OSL_IIB_IMAGE}"
    log "Loaded OSL_VERSION=${OSL_VERSION}"
    log "Loaded OSL_LOGIC_CSV=${OSL_LOGIC_CSV}"
    log "Loaded OSL_CATALOG_SOURCE=${OSL_CATALOG_SOURCE}"
    phase_checkpoint "internal-mirror-prep-complete"
elif [[ -f "${SCRIPT_DIR}/.env.osl" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env.osl"
    log "Loaded existing .env.osl (OSL_LOGIC_CSV=${OSL_LOGIC_CSV:-unset} OSL_CATALOG_SOURCE=${OSL_CATALOG_SOURCE:-unset})"
fi

# ── Pre-deploy: export secrets for envsubst in helm/deploy.sh ───────────────

export BACKEND_SECRET="${BACKEND_SECRET:-$(openssl rand -hex 32)}"
export NODE_TLS_REJECT_UNAUTHORIZED="${NODE_TLS_REJECT_UNAUTHORIZED:-1}"

# ── Pre-deploy: shared orchestrator install spine ───────────────────────────

if [[ -n "${OSL_VERSION:-}" && -n "${OSL_IIB_IMAGE:-}" && -z "${OSL_LOGIC_CSV:-}" ]]; then
    OSL_LOGIC_CSV="logic-operator.v$(extract_major_minor "${OSL_VERSION}").0"
fi

log "Preparing Keycloak before shared orchestrator install..."
prepare_keycloak
sync_keycloak_runtime_env

run_shared_orchestrator_install
assert_pre_release_install_state

# ── Deploy RHDH + orchestrator ──────────────────────────────────────────────

export SONATAFLOW_DATA_INDEX_URL="http://sonataflow-platform-data-index-service.${namespace}.svc.cluster.local"
export IS_AUTH_ENABLED="true"

log "Deploying RHDH $version with shared orchestrator support"
SKIP_ENV_SOURCE=1 \
SKIP_ORCHESTRATOR_INFRA_INSTALL=1 \
./deploy.sh helm "$version" --namespace "$namespace" --with-orchestrator
phase_checkpoint "rhdh-deployed"

rhdh_host="$(oc get route redhat-developer-hub -n "$namespace" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "$rhdh_host" ]]; then
    echo "Error: Could not resolve RHDH route after deploy."
    exit 1
fi
export RHDH_BASE_URL="https://${rhdh_host}"
if declare -F update_rhdh_client_redirects >/dev/null; then
    update_rhdh_client_redirects "$RHDH_BASE_URL"
fi

# ── Verify overlays existing-RHDH contract ───────────────────────────────────

verify_shared_existing_rhdh_contract
phase_checkpoint "overlays-existing-rhdh-prepared"

# ── Wait for RHDH readiness ─────────────────────────────────────────────────

log "Waiting for RHDH to become ready..."
oc rollout status deployment/redhat-developer-hub -n "$namespace" --timeout=600s || {
    echo "Warning: RHDH did not become ready within timeout"
    emit_diag_hints "$namespace"
}
wait_for_rhdh_auth_and_orchestrator_ready "$namespace"
run_post_setup_workflow_smoke "$namespace"

# ── Summary ──────────────────────────────────────────────────────────────────

rhdh_host="$(oc get route redhat-developer-hub -n "$namespace" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
RHDH_URL="${RHDH_BASE_URL:-${rhdh_host:+https://${rhdh_host}}}"
KEYCLOAK_URL="${KEYCLOAK_BASE_URL:-}"

echo ""
echo "==========================================="
echo "  Setup Complete"
echo "==========================================="
echo ""
echo "RHDH URL:      $RHDH_URL"
echo "Keycloak URL:  $KEYCLOAK_URL"
echo "Keycloak Admin: admin / admin123"
echo "Test Users:    test1 / test1@123, test2 / test2@123"
echo ""
DEPLOYED_CV=$(helm list -n "$namespace" -f redhat-developer-hub -o json 2>/dev/null | jq -r '.[0].chart // empty' | sed 's/^redhat-developer-hub-//')
echo "Namespace:     $namespace"
echo "Chart Version: ${DEPLOYED_CV:-unknown}"
echo ""
echo "Pod status:"
oc get pods -n "$namespace" --no-headers 2>/dev/null | sed 's/^/  /'
echo ""
echo "SonataFlow workflows:"
oc get sonataflow -n "$namespace" --no-headers 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo ""
echo "OSL operator versions:"
oc get csv -n openshift-operators --no-headers -o custom-columns='NAME:.metadata.name,VERSION:.spec.version' 2>/dev/null | sed 's/^/  /' || true
echo ""
