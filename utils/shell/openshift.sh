#!/bin/bash
# OpenShift cluster preflight and route URL helpers.

_SHELL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f die >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${_SHELL_LIB_DIR}/common.sh"
fi

require_oc_login() {
    if oc whoami &>/dev/null; then
        return 0
    fi
    if [[ -n "${1:-}" ]]; then
        die "$1"
    fi
    echo "Error: Cannot connect to OpenShift cluster. Is CRC running and are you logged in?" >&2
    echo "  Try: crc start && oc login -u kubeadmin https://api.crc.testing:6443" >&2
    exit 1
}

validate_k8s_namespace() {
    local ns="$1"
    if [[ ! "$ns" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        die "Invalid namespace name: '$ns' (must be lowercase alphanumeric/hyphens, 1-63 chars)"
    fi
}

openshift_route_scheme() {
    local name="$1"
    local ns="$2"
    if oc get route "$name" -n "$ns" -o jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
        echo https
    else
        echo http
    fi
}

openshift_route_url() {
    local name="$1"
    local ns="$2"
    local default_scheme="${3:-https}"
    local host tls scheme
    host="$(oc get route "$name" -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$host" ]] || die "route $name in $ns has no host"
    tls="$(oc get route "$name" -n "$ns" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)"
    scheme="$default_scheme"
    [[ -n "$tls" ]] && scheme="https"
    echo "${scheme}://${host}"
}

openshift_cluster_router_base() {
    local domain host
    domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    if [[ -n "$domain" ]]; then
        echo "$domain"
        return 0
    fi
    host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ "$host" == *.* ]] || die "could not discover cluster router base"
    echo "${host#*.}"
}
