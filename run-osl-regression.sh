#!/bin/bash
#
# Thin OSL RC regression driver (RHIDP-13375).
# Phases: cleanup -> prepare-osl -> deploy -> test.
# Smoke Playwright skips overlays orchestrator.spec.ts beforeAll and greps
# four titles via playwright/osl-regression-smoke.spec.ts.
#
# Usage:
#   ./run-osl-regression.sh --all --rhdh next --osl-release 1.39.0.CR1
#   ./run-osl-regression.sh --cleanup --namespace orchestrator-app-next
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
SMOKE_GREP='Run Greeting workflow and verify Workflows tab|Run Failswitch workflow and verify statuses|Rerun Failswitch from failure point|Execute token-propagation workflow via API'
# Overlays NFS lane (upstream): Playwright project name == k8s namespace.
DEFAULT_NAMESPACE="orchestrator-app-next"

run_all=false
run_cleanup=false
run_prepare=false
run_deploy=false
run_test=false
allow_relative_service_url=false
rhdh=""
osl_release=""
osl_manifest=""
namespace="$DEFAULT_NAMESPACE"
overlays_dir="$DEFAULT_OVERLAYS"

usage() {
    cat <<EOF
Usage: $0 [--all] [--cleanup] [--prepare-osl] [--deploy] [--test] [options]

Phases (any subset; always run in this order): cleanup, prepare-osl, deploy, test.
  --all                         Run all four phases
  --cleanup                     Remove RHDH, Keycloak, workflows, OSL operators, catalog, and mirror
  --prepare-osl                 Mirror OSL images and create CatalogSource
  --deploy                      Deploy Keycloak + RHDH + orchestrator
  --test                        Probe Data Index, then run the four Playwright smoke tests

Options:
  --rhdh <version>              RHDH version (required with --deploy / --test / --all)
  --osl-release <version>       Load config/osl-releases/<version>.json
  --osl-manifest <path>         Explicit OSL manifest path
  --namespace <ns>              RHDH/orchestrator namespace (default: ${DEFAULT_NAMESPACE}).
                                --test requires the namespace to match the overlays
                                Playwright project (NFS: orchestrator-app-next).
  --overlays-dir <path>         rhdh-plugin-export-overlays checkout (NFS lane)
  --allow-relative-service-url  Continue if the osl-di-rewrite GraphQL probe
                                still sees a relative ProcessDefinitions.serviceUrl
                                (SRVLOGIC-1137). Default probe hits the rewrite
                                proxy, not raw Data Index. Also:
                                ALLOW_RELATIVE_SERVICE_URL=1
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
fi

if [[ "$run_cleanup" != "true" && "$run_prepare" != "true" && "$run_deploy" != "true" && "$run_test" != "true" ]]; then
    usage
    die "at least one phase flag (or --all) is required"
fi

overlays_e2e_dir() {
    echo "${overlays_dir}/workspaces/orchestrator/e2e-tests"
}

# NFS Playwright project (upstream overlays). Namespace must match.
resolve_playwright_project() {
    local cfg
    cfg="$(overlays_e2e_dir)/playwright.config.ts"
    [[ -f "$cfg" ]] || die "overlays playwright.config.ts not found: $cfg"
    if grep -Eq 'name:[[:space:]]*["'\'']orchestrator-app-next["'\'']' "$cfg"; then
        echo "orchestrator-app-next"
        return
    fi
    die "overlays checkout lacks NFS Playwright project 'orchestrator-app-next' in $cfg (pass --overlays-dir to an NFS lane checkout)"
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
        [[ -n "$rhdh" ]] || die "--rhdh is required when --test is selected"
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
NAME_SPACE=${namespace}
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
    log "[cleanup] namespace=${namespace} (includes operators/catalog/mirror)"
    "${SCRIPT_DIR}/cleanup.sh" --namespace "$namespace" --include-operators
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
    "${SCRIPT_DIR}/utils/orchestrator/ensure-dataindex-rewrite.sh" "$ns"
}

probe_dataindex() {
    local ns="$1" allow="$2"
    local body url json count problems
    body='{"query":"{ ProcessDefinitions { id serviceUrl endpoint } }"}'
    url="http://osl-di-rewrite.${ns}.svc.cluster.local/graphql"
    log "probing Data Index GraphQL via osl-di-rewrite ProcessDefinitions.serviceUrl"
    json="$(oc exec -n "$ns" deploy/redhat-developer-hub -- \
        curl -sS -X POST -H "Content-Type: application/json" -d "$body" "$url")" \
        || die "oc exec curl of Data Index GraphQL (osl-di-rewrite) failed"
    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        die "Data Index did not return JSON: ${json:0:500}"
    fi
    if printf '%s' "$json" | jq -e '.errors != null and (.errors | length) > 0' >/dev/null; then
        printf '%s\n' "$json" | jq '.errors' >&2
        die "Data Index GraphQL returned errors"
    fi
    count="$(printf '%s' "$json" | jq '.data.ProcessDefinitions | length // 0')"
    if [[ "$count" -eq 0 ]]; then
        printf '%s\n' '{"ok":false,"problems":[{"id":null,"serviceUrl":null,"endpoint":null,"reason":"no-process-definitions"}]}' >&2
        exit 1
    fi
    problems="$(printf '%s' "$json" | jq '[.data.ProcessDefinitions[] | select((.serviceUrl | type != "string") or ((.serviceUrl | startswith("http://") or startswith("https://")) | not)) | {id, serviceUrl, endpoint, reason: "relative-or-missing-serviceUrl"}]')"
    if [[ "$(printf '%s' "$problems" | jq 'length')" -gt 0 ]]; then
        printf '%s\n' "$problems" | jq '{ok:false, problems:.}' >&2
        if [[ "$allow" == "true" ]]; then
            log "WARNING: relative/missing serviceUrl allowed by ALLOW_RELATIVE_SERVICE_URL"
            return 0
        fi
        exit 2
    fi
    printf '%s\n' '{"ok":true,"problems":[]}' >&2
}

phase_deploy() {
    log "[deploy] RHDH ${rhdh} namespace=${namespace}"
    if [[ -f "${SCRIPT_DIR}/.env.osl" ]]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/.env.osl"
    fi
    # NFS env for next/*-CI is set inside deploy.sh before secrets/Helm.
    # Data Index rewrite is installed by setup-orchestrator.sh after Helm.
    POST_SETUP_WORKFLOW_SMOKE=0 \
        SKIP_EMPTY_BASELINE=1 \
        ALLOW_OSL_SERVERLESS_VERSION_SKEW=1 \
        "${SCRIPT_DIR}/setup-orchestrator.sh" "$rhdh" --namespace "$namespace"
}

phase_test() {
    log "[test]"
    overlays_dir="$(cd "$overlays_dir" && pwd)"
    local e2e smoke_spec="" backup="" rc=0 allow_relative=false pw_project
    e2e="$(overlays_e2e_dir)"
    pw_project="$(resolve_playwright_project)"
    if [[ "$namespace" != "$pw_project" ]]; then
        die "OSL Playwright smoke requires --namespace ${pw_project} (overlays project name is the k8s namespace; got '${namespace}')"
    fi
    ensure_e2e_deps "$e2e"

    export K8S_CLUSTER_ROUTER_BASE RHDH_BASE_URL KEYCLOAK_BASE_URL RHDH_VERSION
    export SKIP_KEYCLOAK_DEPLOYMENT=true
    export SKIP_OPERATOR_INSTALLATION=true
    export NAME_SPACE="$namespace"
    export GH_USER_ID=test1
    export GH_USER_PASS=test1@123
    export KEYCLOAK_REALM=rhdh
    export KEYCLOAK_LOGIN_REALM=rhdh
    export KEYCLOAK_CLIENT_ID=rhdh-client
    export KEYCLOAK_CLIENT_SECRET=rhdh-client-secret
    K8S_CLUSTER_ROUTER_BASE="$(cluster_router_base)"
    RHDH_BASE_URL="$(route_url "$RHDH_RELEASE" "$namespace")"
    KEYCLOAK_BASE_URL="$(route_url "$KEYCLOAK_RELEASE" "$KEYCLOAK_NS" http)"
    RHDH_VERSION="$rhdh"
    ensure_dataindex_rewrite "$namespace"

    backup="$(write_overlays_dotenv "$e2e")"
    cleanup_test_artifacts() {
        restore_overlays_dotenv "$e2e" "$backup"
        if [[ -n "${smoke_spec}" && -f "${smoke_spec}" ]]; then
            rm -f "$smoke_spec"
        fi
    }
    trap cleanup_test_artifacts EXIT

    bash "${SCRIPT_DIR}/utils/orchestrator/deploy-smoke-workflows.sh" "$namespace"
    if [[ "$allow_relative_service_url" == "true" || "${ALLOW_RELATIVE_SERVICE_URL:-}" == "1" ]]; then
        allow_relative=true
    fi
    probe_dataindex "$namespace" "$allow_relative"
    smoke_spec="${e2e}/tests/${SMOKE_WRAPPER_NAME}"
    cp -a "$SMOKE_WRAPPER_SRC" "$smoke_spec"

    local pw
    pw="$(playwright_cmd "$e2e")"
    log "Playwright: ${pw} (cwd=${e2e})"
    log "Playwright project: ${pw_project}"
    log "Playwright grep: ${SMOKE_GREP}"
    set +e
    # shellcheck disable=SC2086
    (cd "$e2e" && $pw test --project="$pw_project" --workers=1 --grep "$SMOKE_GREP" "$smoke_spec")
    rc=$?
    set -e

    cleanup_test_artifacts
    trap - EXIT
    smoke_spec=""

    if [[ $rc -ne 0 ]]; then
        log "Playwright failed (exit ${rc}); report: ${e2e}/playwright-report"
        exit "$rc"
    fi
    log "Playwright smoke passed"
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
