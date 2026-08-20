#!/bin/bash
#
# Verify that an existing RHDH namespace satisfies the orchestrator substrate
# contract expected by this repository's setup flow.
#

set -euo pipefail

namespace="orchestrator"
if [[ $# -gt 0 && "$1" != --* ]]; then
  namespace="$1"
  shift
fi

POSTGRES_SECRET="${POSTGRES_SECRET:-backstage-psql-secret}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-backstage-psql}"
REQUIRE_KEYCLOAK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --postgres-secret)
      POSTGRES_SECRET="$2"
      shift 2
      ;;
    --postgres-service)
      POSTGRES_SERVICE="$2"
      shift 2
      ;;
    --require-keycloak)
      REQUIRE_KEYCLOAK=true
      shift
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() {
  echo "==> $*"
}

require_resource() {
  local kind="$1" name="$2" ns="$3"
  if ! oc get "$kind" "$name" -n "$ns" >/dev/null 2>&1; then
    echo "Error: Missing required ${kind}/${name} in namespace ${ns}" >&2
    exit 1
  fi
}

require_route() {
  local name="$1" ns="$2"
  if ! oc get route "$name" -n "$ns" >/dev/null 2>&1; then
    echo "Error: Missing required route/${name} in namespace ${ns}" >&2
    exit 1
  fi
}

resolve_keycloak_route() {
  local host
  for ns in "$namespace" "rhdh-keycloak"; do
    host="$(oc get route keycloak -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [[ -n "$host" ]]; then
      echo "$host"
      return 0
    fi
  done
  return 1
}

main() {
  if ! oc whoami >/dev/null 2>&1; then
    echo "Error: Cannot connect to OpenShift cluster." >&2
    exit 1
  fi

  require_resource "secret" "$POSTGRES_SECRET" "$namespace"
  require_resource "service" "$POSTGRES_SERVICE" "$namespace"
  require_resource "deployment" "sonataflow-platform-data-index-service" "$namespace"
  require_resource "deployment" "sonataflow-platform-jobs-service" "$namespace"
  require_route "redhat-developer-hub" "$namespace"

  if [[ "$REQUIRE_KEYCLOAK" == "true" ]]; then
    if [[ -n "${KEYCLOAK_BASE_URL:-}" ]]; then
      log "Using KEYCLOAK_BASE_URL from environment."
    elif ! resolve_keycloak_route >/dev/null; then
      echo "Error: Missing required Keycloak route (checked ${namespace} and rhdh-keycloak)." >&2
      exit 1
    fi
    fi

  log "Verified existing-RHDH orchestrator prerequisites in namespace ${namespace}."
  log "PostgreSQL secret: ${POSTGRES_SECRET}"
  log "PostgreSQL service: ${POSTGRES_SERVICE}"
}

main "$@"
