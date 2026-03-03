# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides **PR-driven deployment of Red Hat Developer Hub (RHDH) test instances** on OpenShift clusters. Users open a PR (optionally with custom configuration changes) and use the `/test deploy` slash command in PR comments to trigger automated deployment via Prow CI. The system handles cluster provisioning, Keycloak auth setup, RHDH installation, and posts deployment URLs and credentials back to the PR.

Two installation methods are supported (Helm and Operator), with optional Orchestrator components. Local deployment is also possible as a secondary use case. The codebase is entirely Bash scripts and YAML configuration.

## GitHub PR Workflow (Primary Use Case)

Users deploy test instances by commenting on PRs:

```
/test deploy <install-type> <version> [duration]
```

- `install-type`: `helm` or `operator`
- `version`: `1.9`, `1.9-190-CI`, `next`
- `duration`: optional cleanup timer (e.g., `4h`, `2.5h`; default `3h`)

Examples:
```
/test deploy helm 1.7 4h
/test deploy operator 1.6 2.5h
```

The bot responds with RHDH URL, OpenShift console link, and cluster credentials (from Vault). Users can test custom configurations by modifying config files in the PR branch before deploying. Max two concurrent instances.

Prow job status: https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy

## Local Deployment Commands

### Deploy

```bash
# Helm deployment (primary method)
make deploy-helm VERSION=1.9 NAMESPACE=rhdh

# Helm with orchestrator
make deploy-helm VERSION=1.9 ORCH=true

# Operator deployment (requires install-operator first)
make install-operator VERSION=1.9
make deploy-operator VERSION=1.9
```

### Teardown

```bash
make undeploy-helm        # Remove Helm-deployed RHDH
make undeploy-operator    # Remove Operator-deployed RHDH
make undeploy-infra       # Remove Keycloak
make clean                # Remove everything (RHDH + Keycloak)
```

### Debugging

```bash
make status    # Show pod status in namespace
make logs      # Tail RHDH pod logs
make url       # Print the RHDH portal URL
```

### Makefile Variables

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `rhdh` | OpenShift namespace for RHDH |
| `VERSION` | `1.9` | RHDH version (supports `1.9`, `1.9-190-CI`, `next`) |
| `ORCH` | `false` | Enable Orchestrator components |
| `CATALOG_INDEX_TAG` | auto-detected | Plugin catalog index tag |

## Architecture

```
deploy.sh (entry point)
├── Parses args: method (helm/operator), version, namespace, --with-orchestrator
├── Sources secrets from .env (local) or Vault (CI)
├── Deploys Keycloak via utils/keycloak/keycloak-deploy.sh
├── Creates namespace and app-config ConfigMap from config/
└── Delegates to:
    ├── helm/deploy.sh     — Resolves version from Quay API, installs RHDH Helm chart
    └── operator/deploy.sh — Applies Backstage CR after optional operator install
```

### Key directories

- **config/** — RHDH application config (app-config-rhdh.yaml), dynamic plugin definitions, and Kubernetes Secret templates. These are applied as ConfigMaps/Secrets to the cluster.
- **helm/** — Helm-specific deployment: `deploy.sh` resolves chart versions from Quay, `value_file.yaml` provides Helm overrides.
- **operator/** — Operator-based deployment: `install-operator.sh` installs the RHDH operator CRD, `deploy.sh` applies the Backstage CR from `subscription.yaml`.
- **utils/keycloak/** — Full Keycloak deployment automation: Helm install, realm/client/user/group creation via Keycloak REST API. Test users defined in `users.json`, groups in `groups.json`.

### Deployment flow

1. Keycloak is deployed first (Bitnami Helm chart) with an OIDC client (`rhdh-client`) and test users (`test1`/`test2`, password: `test1@123`/`test2@123`).
2. Environment variables (Keycloak URLs, credentials) are exported and substituted into `config/rhdh-secrets.yaml`.
3. `config/app-config-rhdh.yaml` configures RHDH with OIDC auth pointing to Keycloak and catalog entity locations from GitHub.
4. For Helm: the RHDH chart is installed with dynamic plugins config. For Operator: a Backstage CR is applied referencing the ConfigMaps.
5. When `ORCH=true`, orchestrator plugins are merged into `dynamic-plugins.yaml` and serverless operators are installed.

### Secrets

- **PR deployments (primary):** secrets pulled automatically from Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`
- **Local deployments:** secrets loaded from `.env` file (copy `.env.example` to `.env`); Vault is used when `.env` is absent

## Required CLI Tools

`oc`, `helm`, `jq`, `curl`, `podman` (or `docker` for container-based operator install)

## Version Resolution

Helm deploy resolves semantic versions (e.g., `1.9`) to the latest patch by querying the Quay.io API for available chart tags. CI versions like `1.9-190-CI` and `next` are passed through directly.
