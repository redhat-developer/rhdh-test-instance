#!/usr/bin/env bash

# =============================================================================
# config-intelligent-assistant-plugin.sh
#
# The Helm chart and the Operator flavour ship the Intelligent Assistant
# plugins and the no-OKP Lightspeed Core stack that works without an LLM
# provider. When provider credentials are supplied, this script renders the
# chart's stack definition with those providers enabled and creates the
# matching ConfigMap and Secret.
#
# OKP (the offline knowledge portal add-on) is not supported: it is a separate
# Operator flavour and is always off here, so the no-OKP stack is always used.
# =============================================================================

_INTELLIGENT_ASSISTANT_RESOURCES="${DEPLOY_ROOT}/resources/intelligent-assistant"
_INTELLIGENT_ASSISTANT_STACK_NAME="intelligent-assistant-stack"
_INTELLIGENT_ASSISTANT_EGRESS_NAME="rhdh-intelligent-assistant-egress"

LIGHTSPEED_HAS_PROVIDER=false

has_lightspeed_provider() {
    LIGHTSPEED_HAS_PROVIDER=false
    if [[ "${ENABLE_OPENAI:-}" == "true" && -n "${OPENAI_API_KEY:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_VLLM:-}" == "true" && -n "${VLLM_URL:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_OLLAMA:-}" == "true" && -n "${OLLAMA_URL:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_VERTEX_AI:-}" == "true" && -n "${VERTEX_AI_PROJECT:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ -n "${INTELLIGENT_ASSISTANT_STACK_FILE:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    export LIGHTSPEED_HAS_PROVIDER
}

# Merge the enabled providers into the stack definition bundled with the
# selected release, so the rest of the defaults stay in sync with that release.
render_lightspeed_stack() {
    local source_file="$1" providers
    providers=$(yq -o=json '.' "${_INTELLIGENT_ASSISTANT_RESOURCES}/providers.yaml" | jq \
        --arg openai "${ENABLE_OPENAI:-false}" --arg vllm "${ENABLE_VLLM:-false}" \
        --arg ollama "${ENABLE_OLLAMA:-false}" --arg vertexai "${ENABLE_VERTEX_AI:-false}" '
        [.[] | select(.type == "sentence_transformers" or
            (.type == "openai" and $openai == "true") or
            (.type == "vllm" and $vllm == "true") or
            (.type == "ollama" and $ollama == "true") or
            (.type == "vertexai" and $vertexai == "true"))]')
    LCS_PROVIDERS_JSON="$providers" yq '.inference.providers = env(LCS_PROVIDERS_JSON)' "$source_file"
}

# The chart uses lightspeed-stack-no-okp.yaml whenever the OKP add-on is
# disabled, which is always the case here. Copy the matching file so providers
# never end up in a stack that expects an OKP service.
_lightspeed_stack_template() {
    local destination="$1" chart_dir="${DEPLOY_WORKDIR}/chart-source"
    local file_name="lightspeed-stack-no-okp.yaml"
    if fetch_chart "${RHDH_VERSION}" "$chart_dir" \
        && [[ -f "${chart_dir}/chart/files/intelligent-assistant/${file_name}" ]]; then
        cp "${chart_dir}/chart/files/intelligent-assistant/${file_name}" "$destination"
        return 0
    fi
    curl -fsSL "https://raw.githubusercontent.com/redhat-developer/rhdh-chart/$(upstream_branch_for rhdh-chart)/charts/rhdh/files/intelligent-assistant/${file_name}" \
        -o "$destination"
}

setup_intelligent_assistant() {
    has_lightspeed_provider
    if [[ "$LIGHTSPEED_HAS_PROVIDER" == false ]]; then
        echo "No LLM provider configured; using the release's default Intelligent Assistant stack."
        return 0
    fi

    prepare_deploy_workdir
    local stack_file="${DEPLOY_WORKDIR}/lightspeed-stack.yaml"
    if [[ -n "${INTELLIGENT_ASSISTANT_STACK_FILE:-}" ]]; then
        # A supplied stack is kept verbatim, including custom MCP servers/prompts.
        yq '.' "$INTELLIGENT_ASSISTANT_STACK_FILE" > "$stack_file"
    else
        local upstream_stack="${DEPLOY_WORKDIR}/lightspeed-stack.upstream.yaml"
        _lightspeed_stack_template "$upstream_stack" || return 1
        render_lightspeed_stack "$upstream_stack" > "$stack_file"
    fi

    oc create configmap "${_INTELLIGENT_ASSISTANT_STACK_NAME}" \
        --from-file="lightspeed-stack.yaml=${stack_file}" \
        --namespace="${NAMESPACE}" --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"

    export VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
    export VLLM_TLS_VERIFY="${VLLM_TLS_VERIFY:-true}"
    export VERTEX_AI_LOCATION="${VERTEX_AI_LOCATION:-global}"
    export ENABLE_VALIDATION="${ENABLE_VALIDATION:-__disabled__}"
    # Read environment values as JSON strings, preserving quotes/newlines in keys.
    yq -o=json '.' "${_INTELLIGENT_ASSISTANT_RESOURCES}/secret.yaml" \
        | jq '.stringData |= with_entries(.value = (env[.key] // ""))' \
        | oc apply -f - --namespace="${NAMESPACE}"

    # 2.1+ enables default-deny egress. Preserve access to configured plain-HTTP
    # LLM endpoints (HTTPS providers are already allowed by the chart/Operator).
    local ports
    ports=$(python3 -c '
import json, os
from urllib.parse import urlsplit
ports = set()
for provider in ("VLLM", "OLLAMA"):
    if os.environ.get("ENABLE_" + provider) == "true":
        url = urlsplit(os.environ.get(provider + "_URL", ""))
        if url.hostname:
            ports.add(url.port or (443 if url.scheme == "https" else 80))
print(json.dumps(sorted(ports)))
')
    if [[ "$ports" != '[]' ]]; then
        jq -n --argjson ports "$ports" --arg name "$_INTELLIGENT_ASSISTANT_EGRESS_NAME" '{
            apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy",
            metadata: {name: $name},
            spec: {
                podSelector: {matchLabels: {"backstage.io/kubernetes-id": "developer-hub"}},
                policyTypes: ["Egress"], egress: [{ports: [$ports[] | {port: ., protocol: "TCP"}]}]
            }
        }' | oc apply -f - --namespace="${NAMESPACE}"
    fi

    echo "Intelligent Assistant configured with the selected LLM provider."
}
