#!/bin/bash
#
# Probe Data Index GraphQL via osl-di-rewrite for absolute ProcessDefinitions.serviceUrl.
# Usage: probe-dataindex-rewrite.sh <namespace> [allow-relative]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/utils/shell/common.sh"
require_cmd jq

ns="${1:-}"
allow="${2:-false}"
[[ -n "$ns" ]] || die "namespace required"

if [[ "$allow" == "true" || "$allow" == "1" ]]; then
    allow=true
else
    allow=false
fi

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
        exit 0
    fi
    exit 2
fi
printf '%s\n' '{"ok":true,"problems":[]}' >&2
