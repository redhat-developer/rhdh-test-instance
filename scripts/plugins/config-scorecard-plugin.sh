#!/usr/bin/env bash

# =============================================================================
# config-scorecard-plugin.sh
#
# GitHub, Dependabot and OpenSSF metrics use public access. SonarQube is the
# only provider that needs a credential; it is merged into rhdh-secrets without
# touching keys owned by other plugins.
# =============================================================================

configure_scorecard_credentials() {
  local sonarqube_key="${SONARQUBE_API_KEY:-}"
  [[ -n "$sonarqube_key" ]] || return 0
  jq -n --arg sonarqube "$sonarqube_key" '{stringData: {SONARQUBE_API_KEY: $sonarqube}}' |
    oc patch secret rhdh-secrets --namespace="${NAMESPACE}" --type=merge --patch-file=/dev/stdin
  echo "SonarQube credentials configured for Scorecard."
}
