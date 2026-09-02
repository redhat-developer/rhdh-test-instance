#!/bin/bash
#
# Assert OSL/Serverless operator subscriptions and CSV versions after install.
# Requires OSL_* env vars when sourced or invoked. Usage:
#   source utils/orchestrator/assert-osl-operators.sh
#   assert_pre_release_install_state
# Or: bash utils/orchestrator/assert-osl-operators.sh
#
set -euo pipefail

_ASSERT_OSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${_ASSERT_OSL_DIR}/utils/shell/common.sh"

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
        die "${package} channel mismatch. expected='${expected_channel}' actual='${actual_channel}'"
    fi
    if [[ -n "$expected_source" && "$actual_source" != "$expected_source" ]]; then
        die "${package} source mismatch. expected='${expected_source}' actual='${actual_source}'"
    fi
    if [[ -n "$expected_source_ns" && "$actual_source_ns" != "$expected_source_ns" ]]; then
        die "${package} source namespace mismatch. expected='${expected_source_ns}' actual='${actual_source_ns}'"
    fi
    if [[ -n "$expected_starting_csv" && "$actual_starting_csv" != "$expected_starting_csv" ]]; then
        die "${package} startingCSV mismatch. expected='${expected_starting_csv}' actual='${actual_starting_csv}'"
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
        die "Unable to resolve installed logic-operator CSV/version."
    fi

    if [[ -n "${OSL_VERSION:-}" ]]; then
        local osl_marker
        osl_marker="$(echo "${OSL_VERSION}" | tr '[:upper:]' '[:lower:]')"
        local csv_lc version_lc
        csv_lc="$(echo "${logic_csv}" | tr '[:upper:]' '[:lower:]')"
        version_lc="$(echo "${logic_version}" | tr '[:upper:]' '[:lower:]')"
        if [[ "$osl_marker" == *"cr"* || "$osl_marker" == *"rc"* ]]; then
            if [[ "$csv_lc" != *"cr"* && "$csv_lc" != *"rc"* && "$version_lc" != *"cr"* && "$version_lc" != *"rc"* ]]; then
                if [[ -n "${expected_logic_csv:-}" && "$logic_csv" == "$expected_logic_csv" ]]; then
                    log "Pre-release marker not present in CSV/version; accepted because installed CSV matches expected startingCSV (${expected_logic_csv})."
                else
                    die "Expected pre-release OSL marker in installed logic-operator CSV/version. csv='${logic_csv}' version='${logic_version}'"
                fi
            fi
        fi
    fi

    logic_mm="$(extract_major_minor "$logic_version")"
    serverless_mm="$(extract_major_minor "$serverless_version")"
    if [[ -n "$logic_mm" && -n "$serverless_mm" && "$logic_mm" != "$serverless_mm" ]]; then
        if [[ "${ALLOW_OSL_SERVERLESS_VERSION_SKEW:-0}" != "1" ]]; then
            die "Serverless/Logic major.minor mismatch (serverless=${serverless_mm}, logic=${logic_mm}). Set ALLOW_OSL_SERVERLESS_VERSION_SKEW=1 to override."
        fi
        echo "Warning: Serverless/Logic major.minor mismatch allowed by ALLOW_OSL_SERVERLESS_VERSION_SKEW=1 (serverless=${serverless_mm}, logic=${logic_mm})."
    fi

    log "Installed logic-operator CSV: ${logic_csv} (version=${logic_version})"
    log "Installed serverless-operator version: ${serverless_version:-unknown}"
    echo "[CHECKPOINT] operator-configuration-asserted"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    assert_pre_release_install_state
fi
