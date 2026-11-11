#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-smoke.sh — Playwright smoke checks against a live RHDH instance
#
# Shared by `make smoke` and the post-deployment check in deploy.sh (CI).
# Expected plugins default to the selected plugins; every other optional plugin
# is expected to be absent.
#
# Environment:
#   RHDH_BASE_URL    Instance URL (required)
#   PLUGINS          Selected plugins (comma-separated); resolved when empty
#   EXPECT_PLUGINS   Override for the expected plugin list
#   ABSENT_PLUGINS   Override for the plugin list that must not be loaded
#   RHDH_USER / RHDH_PASSWORD   Sign-in credentials (default: test1/test1@123)
#   ARTIFACT_DIR     When set, results are copied there (CI artifacts)
# =============================================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RHDH_BASE_URL:?RHDH_BASE_URL is required}"

# Resolve the selected plugins with the same rules as the deployment, unless
# the caller overrides either list.
if ! resolution=$(
    source "${DIR}/deployment-common.sh"
    resolve_plugins "${PLUGINS:-}" >/dev/null || exit 1
    selected="${PLUGINS_RESOLVED}"
    all=""
    resolve_plugins "all" >/dev/null || exit 1
    for plugin in ${PLUGINS_RESOLVED//,/ }; do
        [[ ",${selected}," == *",${plugin},"* ]] || all="${all:+${all},}${plugin}"
    done
    printf 'RESOLVED_EXPECTED=%q\nRESOLVED_ABSENT=%q\n' "$selected" "$all"
); then
    echo "Error: Could not resolve the plugin list '${PLUGINS:-}'." >&2
    exit 1
fi
eval "$resolution"
EXPECT_PLUGINS="${EXPECT_PLUGINS:-${RESOLVED_EXPECTED}}"
ABSENT_PLUGINS="${ABSENT_PLUGINS:-${RESOLVED_ABSENT}}"

echo "RHDH URL:       ${RHDH_BASE_URL}"
echo "Expected:       ${EXPECT_PLUGINS:-none}"
echo "Must be absent: ${ABSENT_PLUGINS:-none}"

cd "${DIR}/../e2e"
if [[ ! -d node_modules ]]; then
    npm ci
fi

set +e
RHDH_BASE_URL="${RHDH_BASE_URL}" \
    EXPECT_PLUGINS="${EXPECT_PLUGINS}" \
    ABSENT_PLUGINS="${ABSENT_PLUGINS}" \
    npx playwright test
result=$?
set -e

if [[ -n "${ARTIFACT_DIR:-}" && -d results ]]; then
    mkdir -p "${ARTIFACT_DIR}"
    cp -R results/. "${ARTIFACT_DIR}/" || true
fi

exit "$result"
