# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a test deployment framework for **Red Hat Developer Hub (RHDH)** on OpenShift. It provides automated deployment scripts and configuration to spin up fully functional RHDH instances for testing, with integrated Keycloak authentication. It supports both **Helm** and **Operator** installation methods, and can be triggered locally or via PR slash commands in CI (Prow).

## Deployment Commands

### Local deployment (requires `oc` login to an OpenShift cluster)

```bash
# Helm deployment
make deploy-helm VERSION=1.9
make deploy-helm VERSION=1.9-190-CI NAMESPACE=my-rhdh

# Helm with orchestrator
make deploy-helm VERSION=1.9 ORCH=true

# Operator (install operator once, then deploy)
make install-operator VERSION=1.9
make deploy-operator VERSION=1.9

# Status and debugging
make status          # Pods, helm releases, operator versions
make logs            # Tail RHDH pod logs
make url             # Print RHDH instance URL

# Cleanup
make undeploy-helm   # Remove Helm release
make undeploy-operator
make clean           # Delete entire namespace
```

### Direct script usage

```bash
./deploy.sh <method> <version> [--namespace <ns>] [--with-orchestrator]
# Examples: ./deploy.sh helm 1.9, ./deploy.sh operator next --with-orchestrator
```

### PR-based deployment (CI)

Comment on a PR: `/test deploy <helm|operator> <version> [duration]`

## Architecture

### Deployment flow

`deploy.sh` is the main entry point. It:
1. Sources `.env` (local) or uses Vault secrets (CI)
2. Deploys Keycloak via `utils/keycloak/keycloak-deploy.sh`
3. Creates namespace and applies `app-config-rhdh` ConfigMap
4. Delegates to `helm/deploy.sh` or `operator/deploy.sh`
5. Waits for rollout

### Helm vs Operator differences

- **Helm** (`helm/deploy.sh`): Resolves chart version from `oci://quay.io/rhdh/chart`, builds dynamic plugins value file (escaping `{{inherit}}` for Go templates), installs chart with values from `helm/value_file.yaml`
- **Operator** (`operator/deploy.sh`): Requires pre-installed operator CRD (`backstages.rhdh.redhat.com`), creates `dynamic-plugins` ConfigMap separately, applies Backstage CR from `operator/subscription.yaml` using `envsubst`
- **RHDH URL differs**: Helm uses `redhat-developer-hub-<ns>`, Operator uses `backstage-developer-hub-<ns>` as route prefix

### Configuration files

| File | Purpose |
|------|---------|
| `config/app-config-rhdh.yaml` | Backstage app config (auth, catalog, providers). Uses `${VAR}` env substitution |
| `config/dynamic-plugins.yaml` | Plugin list. Uses `{{inherit}}` for version resolution from catalog index |
| `config/orchestrator-dynamic-plugins.yaml` | Orchestrator plugins, merged when `ORCH=true` |
| `config/rhdh-secrets.yaml` | K8s Secret template, processed with `envsubst` at deploy time |
| `helm/value_file.yaml` | Helm chart value overrides |
| `operator/subscription.yaml` | Backstage CR template for operator deployments |

### Environment and secrets

- **Local**: `.env` file (copy from `.env.example`), sourced at start of `deploy.sh`
- **CI**: Vault at `selfservice/rhdh-test-instance/` — secrets become env vars automatically
- Keycloak vars (`KEYCLOAK_*`) are auto-set by `keycloak-deploy.sh`
- `RHDH_BASE_URL` is auto-set by the deploy scripts

### Version handling

- Semantic versions (e.g., `1.9`) resolve to latest chart version matching that prefix
- CI versions (e.g., `1.9-190-CI`) are used directly
- `next` maps to `main` branch for operator, and uses `next` catalog index tag
- `CATALOG_INDEX_TAG` defaults to major.minor from version, overridable

## Key Patterns

- All shell scripts use `set -e` and `source` (not subshells) so variables propagate
- Orchestrator support conditionally installs Knative Serverless and Serverless Logic operators if not present
- Helm deploy does a scale-down/scale-up cycle after install to pick up config changes
- The `{{inherit}}` tag in dynamic-plugins.yaml resolves plugin versions from the catalog index image at runtime
