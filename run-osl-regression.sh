#!/bin/bash
#
# Thin OSL RC regression driver (RHIDP-13375).
# Phases: cleanup -> prepare-osl -> deploy -> test.
# Smoke Playwright skips overlays orchestrator.spec.ts beforeAll and greps
# four titles via playwright/osl-regression-smoke.spec.ts.
#
# Usage:
#   ./run-osl-regression.sh --all --rhdh next --osl-release 1.39.0.CR1
#   ./run-osl-regression.sh --cleanup --include-operators --namespace orchestrator
#   ./run-osl-regression.sh --test --overlays-dir ../rhdh-plugin-export-overlays
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_git_common="$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null)"
_main_repo_root="$(cd "$SCRIPT_DIR" && cd "$_git_common/.." 2>/dev/null && pwd)"
WORKSPACE_DIR="$(dirname "${_main_repo_root:-$SCRIPT_DIR}")"
unset _git_common _main_repo_root

DEFAULT_OVERLAYS="${WORKSPACE_DIR}/rhdh-plugin-export-overlays"
KEYCLOAK_NS="rhdh-keycloak"
KEYCLOAK_RELEASE="keycloak"
RHDH_RELEASE="redhat-developer-hub"
SMOKE_WRAPPER_SRC="${SCRIPT_DIR}/playwright/osl-regression-smoke.spec.ts"
SMOKE_WRAPPER_NAME="osl-regression-smoke.spec.ts"
WORKFLOW_REPO="${SERVERLESS_WORKFLOWS_REPO:-https://github.com/rhdhorchestrator/serverless-workflows.git}"
WORKFLOW_REPO_REF="${SERVERLESS_WORKFLOWS_REF:-daeeee8dec16beab6d96a81774ef500081a2c2b0}"
DEMO_WORKFLOW_REPO="${ORCHESTRATOR_DEMO_REPO:-https://github.com/rhdhorchestrator/orchestrator-demo.git}"

run_all=false
run_cleanup=false
run_prepare=false
run_deploy=false
run_test=false
include_operators=false
full_e2e=false
allow_relative_service_url=false
rhdh=""
osl_release=""
osl_manifest=""
namespace="orchestrator"
overlays_dir="$DEFAULT_OVERLAYS"

usage() {
    cat <<EOF
Usage: $0 [--all] [--cleanup] [--prepare-osl] [--deploy] [--test] [options]

Phases (any subset; always run in this order): cleanup, prepare-osl, deploy, test.
  --all                         Run all four phases; cleanup includes operators

Options:
  --rhdh <version>              RHDH version (required with --deploy / --all)
  --osl-release <version>       Load config/osl-releases/<version>.json
  --osl-manifest <path>         Explicit OSL manifest path
  --namespace <ns>              RHDH/orchestrator namespace (default: orchestrator)
  --overlays-dir <path>         rhdh-plugin-export-overlays checkout
  --include-operators           Cleanup also removes operators/catalog/mirror
  --full-e2e                    Full overlays orchestrator Playwright project
  --allow-relative-service-url  Continue smoke if Data Index serviceUrl is relative
  -h, --help                    Show this help
EOF
}

log() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)                run_all=true; shift ;;
        --cleanup)            run_cleanup=true; shift ;;
        --prepare-osl)        run_prepare=true; shift ;;
        --deploy)             run_deploy=true; shift ;;
        --test)               run_test=true; shift ;;
        --rhdh)               rhdh="${2:-}"; shift 2 ;;
        --osl-release)        osl_release="${2:-}"; shift 2 ;;
        --osl-manifest)       osl_manifest="${2:-}"; shift 2 ;;
        --namespace)          namespace="${2:-}"; shift 2 ;;
        --overlays-dir)       overlays_dir="${2:-}"; shift 2 ;;
        --include-operators)  include_operators=true; shift ;;
        --full-e2e)           full_e2e=true; shift ;;
        --allow-relative-service-url) allow_relative_service_url=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    usage; die "unknown option: $1" ;;
    esac
done

if [[ "$run_all" == "true" ]]; then
    run_cleanup=true
    run_prepare=true
    run_deploy=true
    run_test=true
    include_operators=true
fi

if [[ "$run_cleanup" != "true" && "$run_prepare" != "true" && "$run_deploy" != "true" && "$run_test" != "true" ]]; then
    usage
    die "at least one phase flag (or --all) is required"
fi

overlays_e2e_dir() {
    echo "${overlays_dir}/workspaces/orchestrator/e2e-tests"
}

resolve_manifest() {
    if [[ -n "$osl_manifest" ]]; then
        echo "$osl_manifest"
        return
    fi
    if [[ -n "$osl_release" ]]; then
        echo "${SCRIPT_DIR}/config/osl-releases/${osl_release}.json"
        return
    fi
    echo ""
}

preflight() {
    require_cmd oc
    require_cmd helm
    require_cmd jq
    oc whoami >/dev/null 2>&1 || die "oc whoami failed; log into a cluster first"

    if [[ "$run_prepare" == "true" ]]; then
        require_cmd podman
        require_cmd skopeo
        require_cmd python
        local manifest
        manifest="$(resolve_manifest)"
        [[ -n "$manifest" ]] || die "--prepare-osl requires --osl-release or --osl-manifest"
        [[ -f "$manifest" ]] || die "OSL manifest not found: $manifest"
    fi

    if [[ "$run_deploy" == "true" ]]; then
        [[ -n "$rhdh" ]] || die "--rhdh is required when --deploy is selected"
        if [[ "$run_prepare" != "true" && ! -f "${SCRIPT_DIR}/.env.osl" ]]; then
            die ".env.osl is missing; run --prepare-osl first or include it in this invocation"
        fi
    fi

    if [[ "$run_test" == "true" ]]; then
        require_cmd git
        local pkg
        pkg="$(overlays_e2e_dir)/package.json"
        [[ -f "$pkg" ]] || die "overlays e2e package.json not found: $pkg (pass --overlays-dir)"
        [[ -f "$SMOKE_WRAPPER_SRC" ]] || die "missing smoke wrapper: $SMOKE_WRAPPER_SRC"
        if ! command -v yarn >/dev/null 2>&1 && ! command -v corepack >/dev/null 2>&1; then
            die "yarn or corepack is required for --test"
        fi
    fi
}

cluster_router_base() {
    local domain
    domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    if [[ -n "$domain" ]]; then
        echo "$domain"
        return
    fi
    local host
    host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ "$host" == *.* ]] || die "could not discover cluster router base"
    echo "${host#*.}"
}

route_url() {
    local name="$1" ns="$2" default_scheme="${3:-https}"
    local host tls scheme
    host="$(oc get route "$name" -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$host" ]] || die "route $name in $ns has no host"
    tls="$(oc get route "$name" -n "$ns" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)"
    scheme="$default_scheme"
    [[ -n "$tls" ]] && scheme="https"
    echo "${scheme}://${host}"
}

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
    local ns="$1" name="$2" tag="${3:-}" image persistence
    persistence="{
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
        }
      }
    }"
    case "$name" in
        greeting)   image="quay.io/orchestrator/serverless-workflow-greeting:osl_${tag}" ;;
        failswitch) image="quay.io/orchestrator/fail-switch:osl_${tag}" ;;
        token-propagation)
            oc -n "$ns" patch sonataflow "$name" --type merge -p "$persistence" >/dev/null || true
            return 0
            ;;
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
    }" >/dev/null || true
}

wait_smoke_workflows_ready() {
    local ns="$1" timeout_secs="${2:-600}" start elapsed ready
    start="$(date +%s)"
    while true; do
        ready=true
        for name in greeting failswitch token-propagation; do
            local replicas
            replicas="$(oc get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
            if [[ "$replicas" != "1" ]]; then
                ready=false
            fi
        done
        if [[ "$ready" == "true" ]]; then
            log "smoke workflows greeting/failswitch/token-propagation are ready"
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= timeout_secs )); then
            die "timeout waiting for greeting/failswitch/token-propagation deployments in $ns"
        fi
        sleep 10
    done
}

ensure_token_propagation_workflow() {
    local ns="$1"
    local demo_dir manifests_dir props_cm specs_cm
    [[ -n "${KEYCLOAK_BASE_URL:-}" ]] || die "KEYCLOAK_BASE_URL is required for token-propagation smoke"
    log "deploying token-propagation workflow and sample-server"
    demo_dir="$(mktemp -d /tmp/osl-token-demo-XXXXXX)"
    _osl_token_demo_cleanup() { rm -rf "$demo_dir"; trap - RETURN; }
    trap _osl_token_demo_cleanup RETURN
    git clone --depth 1 "$DEMO_WORKFLOW_REPO" "$demo_dir" >/dev/null
    manifests_dir="${demo_dir}/09_token_propagation/manifests"
    props_cm="${manifests_dir}/01-configmap_token-propagation-props.yaml"
    specs_cm="${manifests_dir}/03-configmap_02-token-propagation-resources-specs.yaml"
    [[ -f "$props_cm" && -f "$specs_cm" ]] || die "token-propagation manifests missing in $DEMO_WORKFLOW_REPO"
    python3 - "$ns" "$props_cm" "$specs_cm" <<'PY'
from pathlib import Path
import os
import sys

ns, props_path, specs_path = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
kc = os.environ["KEYCLOAK_BASE_URL"].rstrip("/")
realm = os.environ.get("KEYCLOAK_REALM", "rhdh")
client_id = os.environ.get("KEYCLOAK_CLIENT_ID", "rhdh-client")
client_secret = os.environ.get("KEYCLOAK_CLIENT_SECRET", "rhdh-client-secret")
auth_server_url = f"{kc}/realms/{realm}"
token_url = f"{auth_server_url}/protocol/openid-connect/token"
props = props_path.read_text()
props = props.replace(
    "http://example-kc-service.keycloak:8080/realms/quarkus",
    auth_server_url,
)
props = props.replace("client-id=quarkus-app", f"client-id={client_id}")
props = props.replace(
    "client-secret=lVGSvdaoDUem7lqeAnqXn1F92dCPbQea",
    f"client-secret={client_secret}",
)
props = props.replace(
    "http://sample-server-service.rhdh-operator",
    f"http://sample-server-service.{ns}:8080",
)
props_path.write_text(props)
specs_path.write_text(
    specs_path.read_text().replace(
        "http://example-kc-service.keycloak:8080/realms/quarkus/protocol/openid-connect/token",
        token_url,
    )
)
PY
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
          image: quay.io/orchestrator/sample-server:latest
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
    patch_smoke_workflow "$ns" token-propagation
}

ensure_smoke_workflows() {
    local ns="$1"
    local tag
    tag="$(workflow_osl_image_tag)"
    log "deploying smoke workflows (image tag osl_${tag})"
    local workflow_dir
    workflow_dir="$(mktemp -d /tmp/osl-workflows-XXXXXX)"
    git clone --depth 1 "$WORKFLOW_REPO" "$workflow_dir" >/dev/null
    git -C "$workflow_dir" fetch --depth 1 origin "$WORKFLOW_REPO_REF" >/dev/null
    git -C "$workflow_dir" checkout --detach "$WORKFLOW_REPO_REF" >/dev/null
    oc apply -n "$ns" -f "${workflow_dir}/workflows/greeting/manifests"
    oc apply -n "$ns" -f "${workflow_dir}/workflows/fail-switch/src/main/resources/manifests"
    rm -rf "$workflow_dir"
    patch_smoke_workflow "$ns" greeting "$tag"
    patch_smoke_workflow "$ns" failswitch "$tag"
    ensure_token_propagation_workflow "$ns"
    wait_smoke_workflows_ready "$ns" 600
    oc rollout restart "deploy/sonataflow-platform-data-index-service" -n "$ns" >/dev/null 2>&1 || true
    oc rollout status "deploy/sonataflow-platform-data-index-service" -n "$ns" --timeout=180s >/dev/null 2>&1 || true
}

ensure_e2e_deps() {
    local e2e="$1"
    if [[ -d "${e2e}/node_modules" ]]; then
        return 0
    fi
    log "yarn install in ${e2e}"
    if command -v corepack >/dev/null 2>&1; then
        (cd "$e2e" && corepack yarn install)
    elif command -v npx >/dev/null 2>&1; then
        (cd "$e2e" && npx --yes corepack yarn install)
    else
        (cd "$e2e" && yarn install)
    fi
}

playwright_cmd() {
    local e2e="$1"
    local local_bin="${e2e}/node_modules/.bin/playwright"
    if [[ -x "$local_bin" ]]; then
        echo "$local_bin"
        return
    fi
    if command -v corepack >/dev/null 2>&1; then
        echo "corepack yarn playwright"
        return
    fi
    echo "yarn playwright"
}

write_overlays_dotenv() {
    local e2e="$1"
    local path="${e2e}/.env"
    local backup=""
    if [[ -f "$path" ]]; then
        backup="${e2e}/.env.osl-regression.bak"
        cp -a "$path" "$backup"
    fi
    cat > "$path" <<EOF
K8S_CLUSTER_ROUTER_BASE=${K8S_CLUSTER_ROUTER_BASE}
RHDH_BASE_URL=${RHDH_BASE_URL}
RHDH_VERSION=${RHDH_VERSION:-}
ORCH_E2E_USE_EXISTING_RHDH=true
ORCH_E2E_SKIP_WORKFLOW_DEPLOY=false
ORCH_E2E_SKIP_BASELINE_RBAC=false
SKIP_KEYCLOAK_DEPLOYMENT=true
SKIP_OPERATOR_INSTALLATION=true
GH_USER_ID=test1
GH_USER_PASS=test1@123
KEYCLOAK_BASE_URL=${KEYCLOAK_BASE_URL}
KEYCLOAK_REALM=rhdh
KEYCLOAK_LOGIN_REALM=rhdh
KEYCLOAK_CLIENT_ID=rhdh-client
KEYCLOAK_CLIENT_SECRET=rhdh-client-secret
EOF
    echo "$backup"
}

restore_overlays_dotenv() {
    local e2e="$1" backup="$2"
    local path="${e2e}/.env"
    if [[ -n "$backup" && -f "$backup" ]]; then
        mv "$backup" "$path"
        return
    fi
    rm -f "$path"
}

phase_cleanup() {
    log "[cleanup] namespace=${namespace} include_operators=${include_operators}"
    local args=(--namespace "$namespace")
    if [[ "$include_operators" == "true" ]]; then
        args+=(--include-operators)
    fi
    "${SCRIPT_DIR}/cleanup.sh" "${args[@]}"
}

phase_prepare() {
    log "[prepare-osl]"
    local args=()
    if [[ -n "$osl_manifest" ]]; then
        args+=(--release-manifest "$osl_manifest")
        [[ -n "$osl_release" ]] && args+=(--release "$osl_release")
    else
        args+=(--release "$osl_release")
    fi
    args+=(--namespace "$namespace")
    "${SCRIPT_DIR}/prepare-osl-internal.sh" "${args[@]}"
}

ensure_dataindex_rewrite() {
    local ns="$1"
    local name="osl-di-rewrite"
    local image rewrite_url oidc_tmp
    image="$(oc get deploy redhat-developer-hub -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [[ -n "$image" ]] || die "cannot resolve RHDH image for data-index rewrite proxy"
    rewrite_url="http://${name}.${ns}.svc.cluster.local"
    log "ensuring data-index rewrite proxy ${name} -> sonataflow-platform-data-index-service"
    oc create configmap "$name" \
        --from-file=osl-di-rewrite.js="${SCRIPT_DIR}/utils/orchestrator/osl-di-rewrite.js" \
        -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
    oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: rewrite
          image: ${image}
          command: ["node", "/opt/app-root/src/osl-di-rewrite.js"]
          env:
            - name: OSL_DI_UPSTREAM
              value: http://sonataflow-platform-data-index-service.${ns}.svc.cluster.local
            - name: PORT
              value: "8080"
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            tcpSocket:
              port: 8080
            periodSeconds: 5
          volumeMounts:
            - name: script
              mountPath: /opt/app-root/src/osl-di-rewrite.js
              subPath: osl-di-rewrite.js
      volumes:
        - name: script
          configMap:
            name: ${name}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: ${name}
spec:
  selector:
    app: ${name}
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOF
    oc rollout status "deploy/${name}" -n "$ns" --timeout=180s >/dev/null
    oidc_tmp="$(mktemp)"
    oc get configmap app-config-oidc -n "$ns" -o jsonpath='{.data.app-config-oidc\.yaml}' > "$oidc_tmp"
    python - "$oidc_tmp" "$rewrite_url" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
url = sys.argv[2]
text = path.read_text()
lines = []
replaced = False
for line in text.splitlines():
    if line.strip().startswith("url:") and not replaced:
        indent = line[: len(line) - len(line.lstrip())]
        lines.append(f"{indent}url: {url}")
        replaced = True
    else:
        lines.append(line)
path.write_text("\n".join(lines) + "\n")
PY
    oc create configmap app-config-oidc \
        --from-file=app-config-oidc.yaml="$oidc_tmp" \
        -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
    rm -f "$oidc_tmp"
    oc rollout restart "deploy/redhat-developer-hub" -n "$ns" >/dev/null
    oc rollout status "deploy/redhat-developer-hub" -n "$ns" --timeout=300s >/dev/null
    log "data-index rewrite proxy ready (${rewrite_url})"
}

phase_deploy() {
    log "[deploy] RHDH ${rhdh} namespace=${namespace}"
    if [[ -f "${SCRIPT_DIR}/.env.osl" ]]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/.env.osl"
    fi
    POST_SETUP_WORKFLOW_SMOKE=0 \
        SKIP_EMPTY_BASELINE=1 \
        ALLOW_OSL_SERVERLESS_VERSION_SKEW=1 \
        "${SCRIPT_DIR}/setup-orchestrator.sh" "$rhdh" --namespace "$namespace"
    ensure_dataindex_rewrite "$namespace"
}

phase_test() {
    log "[test]"
    overlays_dir="$(cd "$overlays_dir" && pwd)"
    local e2e smoke_spec="" backup="" rc=0 smoke_grep=""
    local -a probe_args
    e2e="$(overlays_e2e_dir)"
    ensure_e2e_deps "$e2e"

    export K8S_CLUSTER_ROUTER_BASE RHDH_BASE_URL KEYCLOAK_BASE_URL RHDH_VERSION
    export ORCH_E2E_USE_EXISTING_RHDH=true
    export ORCH_E2E_SKIP_WORKFLOW_DEPLOY=false
    export ORCH_E2E_SKIP_BASELINE_RBAC=false
    export SKIP_KEYCLOAK_DEPLOYMENT=true
    export SKIP_OPERATOR_INSTALLATION=true
    export GH_USER_ID=test1
    export GH_USER_PASS=test1@123
    export KEYCLOAK_REALM=rhdh
    export KEYCLOAK_LOGIN_REALM=rhdh
    export KEYCLOAK_CLIENT_ID=rhdh-client
    export KEYCLOAK_CLIENT_SECRET=rhdh-client-secret
    K8S_CLUSTER_ROUTER_BASE="$(cluster_router_base)"
    RHDH_BASE_URL="$(route_url "$RHDH_RELEASE" "$namespace")"
    KEYCLOAK_BASE_URL="$(route_url "$KEYCLOAK_RELEASE" "$KEYCLOAK_NS" http)"
    RHDH_VERSION="${rhdh}"
    ensure_dataindex_rewrite "$namespace"

    backup="$(write_overlays_dotenv "$e2e")"
    cleanup_test_artifacts() {
        restore_overlays_dotenv "$e2e" "$backup"
        if [[ -n "${smoke_spec}" && -f "${smoke_spec}" ]]; then
            rm -f "$smoke_spec"
        fi
    }
    trap cleanup_test_artifacts EXIT

    if [[ "$full_e2e" != "true" ]]; then
        ensure_smoke_workflows "$namespace"
        probe_args=(python3 "${SCRIPT_DIR}/utils/orchestrator/osl_smoke.py" probe --namespace "$namespace")
        if [[ "$allow_relative_service_url" == "true" || "${ALLOW_RELATIVE_SERVICE_URL:-}" == "1" ]]; then
            probe_args+=(--allow-relative)
        fi
        log "probing raw Data Index GraphQL ProcessDefinitions.serviceUrl"
        "${probe_args[@]}"
        smoke_spec="${e2e}/tests/${SMOKE_WRAPPER_NAME}"
        cp -a "$SMOKE_WRAPPER_SRC" "$smoke_spec"
    fi

    local pw
    pw="$(playwright_cmd "$e2e")"
    log "Playwright: ${pw} (cwd=${e2e})"
    set +e
    if [[ "$full_e2e" == "true" ]]; then
        # shellcheck disable=SC2086
        (cd "$e2e" && $pw test --project=orchestrator --workers=1)
    else
        smoke_grep="$(python3 "${SCRIPT_DIR}/utils/orchestrator/osl_smoke.py" grep)"
        log "Playwright grep: ${smoke_grep}"
        # shellcheck disable=SC2086
        (cd "$e2e" && $pw test --project=orchestrator --workers=1 --grep "$smoke_grep" "$smoke_spec")
    fi
    rc=$?
    set -e

    cleanup_test_artifacts
    trap - EXIT
    smoke_spec=""

    if [[ $rc -ne 0 ]]; then
        log "Playwright failed (exit ${rc}); report: ${e2e}/playwright-report"
        exit "$rc"
    fi
    log "Playwright smoke/full suite passed"
}

preflight

if [[ "$run_cleanup" == "true" ]]; then
    phase_cleanup
fi
if [[ "$run_prepare" == "true" ]]; then
    phase_prepare
fi
if [[ "$run_deploy" == "true" ]]; then
    phase_deploy
fi
if [[ "$run_test" == "true" ]]; then
    phase_test
fi
