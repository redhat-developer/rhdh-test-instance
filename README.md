# RHDH Test Instance

A comprehensive test instance setup for **Red Hat Developer Hub (RHDH)** on OpenShift, providing a ready-to-use developer portal with authentication, app-config, and dynamic plugin config.

## Overview

This project provides automated deployment scripts and configuration files to set up a fully functional RHDH test instance on OpenShift.

### Features

- 🤖 **GitHub PR Integration** with `/test` command for on-demand deployments
- 📦 **Multiple Install Types**: Support for both Helm and Operator installation methods
- 🔄 **Flexible Version Support**: Deploy any RHDH version (latest, semantic versions like 1.7, CI builds like 1.7-98-CI)
- 🌐 **Cluster Information Sharing**: Automatic sharing of deployment URLs, OpenShift console access, and cluster credentials
- 🔐 **Integrated Keycloak Authentication**: Automatic Keycloak deployment with pre-configured realm and test users
- 👥 **Pre-configured Test Users**: Ready-to-use test accounts (test1, test2) with authentication setup
- 🏠 **Local Deployment**: Support for local development and testing environments
- ⚡ **Resource Management**: Automatic cleanup with configurable timers and resource limits
- 🎯 **Instance Limits**: Maximum of two concurrent test instances to manage resource usage
- 💬 **User-friendly feedback** with deployment status comments and live URLs
- 🛠️ **Debug & Customization Support**: Shared cluster credentials for troubleshooting and custom configurations

## GitHub PR Workflow Integration

Deploy test environments directly from Pull Requests using slash commands and test different configurations without local setup.

### Slash Commands

The bot supports flexible deployment commands directly from PR comments:

```
/test deploy <install-type> <version> [duration]
```

**Parameters:**
- `install-type`: `helm` or `operator`
- `version`: Version to deploy (see supported versions below)
- `duration`: Optional cleanup timer (e.g., `4h`, `2.5h`)

**Examples:**
```
/test deploy helm 1.7 4h          # Deploy RHDH 1.7 with Helm, cleanup after 4 hours
/test deploy operator 1.6 2.5h     # Deploy RHDH 1.6 with Operator, cleanup after 2.5 hours
/test deploy helm 1.7            # Deploy latest CI version with Helm with defaut duration 3h
/test deploy operator 1.7-98-CI   # Deploy specific CI build with Operator
```

### How to Use PR Integration

1. **Comment on any PR on rhdh-test-instance repo:**
   ```
   /test deploy helm 1.7 4h
   ```

### Feedback Loop

The bot provides comprehensive feedback through PR comments for eg:

```
🚀 Deployed RHDH version: 1.7 using helm

🌐 RHDH URL: https://redhat-developer-hub-rhdh.apps.rhdh-4-17-us-east-2-kz69l.rhdh-qe.devcluster.openshift.com

🖥️ OpenShift Console: Open Console

🔑 Cluster Credentials: Available in vault under ocp-cluster-creds with keys:
• Username: CLUSTER_ADMIN_USERNAME
• Password: CLUSTER_ADMIN_PASSWORD

⏰ Cluster Availability: Next 1 hours
```



### Live Status of deploy Job

**Prow Status:**
https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy

**Job History:**
https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-redhat-developer-rhdh-test-instance-main-deploy

### Testing Custom Configurations via PRs

Users can deploy different configuration flavors by:

1. **Creating a PR** with modified configuration files
2. **Using bot commands** to deploy the PR's configuration:
   ```
   /test deploy helm 1.7 2h
   ```

## Local Deployment

For local development and testing environments, you can deploy RHDH directly to your OpenShift cluster.

> **Note: Bring Your Own Cluster (BYOC)**  
> Local deployment requires you to have access to your own OpenShift cluster.

### Prerequisites

- `oc` CLI logged into your OpenShift cluster
- `helm` CLI installed
- `make` installed
- `.env` file configured with Keycloak credentials (copy from `.env.example`)

### Quick Start

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd rhdh-test-instance
   ```

2. **Configure environment:**
   ```bash
   cp .env.example .env
   # Edit .env with your Keycloak credentials
   ```

3. **Deploy RHDH:**
   ```bash
   make deploy-helm VERSION=1.9-190-CI
   ```

4. **Access your RHDH instance:**
   ```bash
   make url
   ```

### Make Commands

Run `make help` to see all available commands.

#### Deploy

```bash
# Helm
make deploy-helm VERSION=1.9
make deploy-helm VERSION=1.9 NAMESPACE=my-rhdh

# Helm + Orchestrator
make deploy-helm VERSION=1.9 ORCH=true

# Operator (one-time operator install, then deploy instance)
make install-operator VERSION=1.9
make deploy-operator VERSION=1.9

# Operator + Orchestrator
make deploy-operator VERSION=1.9 ORCH=true
```

#### Cleanup

```bash
make undeploy-helm                    # Remove Helm release
make undeploy-operator                # Remove Operator deployment
make undeploy-infra                   # Remove orchestrator infra chart
make clean                            # Delete the entire namespace
```

#### Status and Debugging

```bash
make status                           # Pods, helm releases, operator versions
make logs                             # Tail RHDH pod logs
make url                              # Print RHDH URL
```

#### Configuration

All make commands accept these variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `rhdh` | Target namespace |
| `VERSION` | `1.9` | RHDH version (`1.9`, `1.9-190-CI`, or `next`) |
| `ORCH` | `false` | Set to `true` to deploy with orchestrator support |
| `USE_CONTAINER` | `false` | Set to `true` to run commands inside the e2e-runner container |
| `CATALOG_INDEX_TAG` | auto | Catalog index image tag (defaults to major.minor from version, or `next`) |
| `RUNNER_IMAGE` | `quay.io/rhdh-community/rhdh-e2e-runner:main` | Container image for `install-operator` |

> **Note:** `install-operator` requires you to be logged into the cluster via `oc login` on your host.
> It automatically passes the session token to the e2e-runner container (needs Linux tools like `umoci`, `opm`, `skopeo`).
> The operator is installed once per cluster. After that, `deploy-operator` runs locally like `deploy-helm`.

### Direct Script Usage

You can also use `deploy.sh` directly:

```bash
./deploy.sh <installation-method> <version> [--namespace <ns>] [--with-orchestrator]
```

**Examples:**
```bash
./deploy.sh helm 1.9
./deploy.sh helm 1.9-190-CI
./deploy.sh helm next
./deploy.sh helm 1.9 --namespace rhdh-helm --with-orchestrator
./deploy.sh operator 1.9 --namespace rhdh-operator
./deploy.sh operator next --with-orchestrator
```

### Accessing Your Local RHDH Instance

After successful installation, access your RHDH instance at:
```
https://redhat-developer-hub-<namespace>.<cluster-router-base>
```

### Login Process

1. Navigate to the RHDH URL
2. Click "Sign In"
3. Use one of the test users (test1/test1@123 or test2/test2@123)
4. Explore the developer portal features

## Configuration

### Application Configuration

The main application configuration is stored in `config/app-config-rhdh.yaml`:

```yaml
# Key configuration areas:
app:
  baseUrl: "${RHDH_BASE_URL}"
  
auth:
  environment: production
  providers:
    oidc:
      production:
        metadataUrl: "${KEYCLOAK_METADATA_URL}"
        clientId: "${KEYCLOAK_CLIENT_ID}"
        clientSecret: "${KEYCLOAK_CLIENT_SECRET}"

catalog:
  locations:
    - type: url
      target: https://github.com/redhat-developer/rhdh/blob/main/catalog-entities/all.yaml
```

### Dynamic Plugins

Configure dynamic plugins in `config/dynamic-plugins.yaml`:

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-community-plugin-catalog-backend-module-keycloak-dynamic
    disabled: false
```

Orchestrator plugins are configured separately in `config/orchestrator-dynamic-plugins.yaml` and merged automatically when `ORCH=true` is set.

> **Note:** The `{{inherit}}` tag resolves the plugin version from the catalog index image at runtime.

### Helm Values

Customize deployment in `helm/value_file.yaml`:

```yaml
upstream:
  backstage:
    extraAppConfig:
      - configMapRef: app-config-rhdh
        filename: app-config-rhdh.yaml
    extraEnvVarsSecrets:
      - rhdh-secrets
```

## Authentication with Keycloak

### Automatic Keycloak Deployment

The installation script automatically deploys Keycloak with:
- Admin user: `admin` / `admin123`
- Predefined realm: `rhdh`
- Pre-configured OIDC client
- Test users for development

### Test Users

The following test users are created automatically:

| Username | Password | Email | Role |
|----------|----------|--------|------|
| test1 | test1@123 | test1@example.com | User |
| test2 | test2@123 | test2@example.com | User |

### Keycloak Configuration

Keycloak is configured with:
- **Realm**: `rhdh`
- **Client ID**: `rhdh-client`

## Project Structure

```
rhdh-test-instance/
├── config/
│   ├── app-config-rhdh.yaml                # Main RHDH configuration
│   ├── dynamic-plugins.yaml                # Dynamic plugins configuration
│   ├── orchestrator-dynamic-plugins.yaml   # Orchestrator plugins (merged when ORCH=true)
│   └── rhdh-secrets.yaml                   # Kubernetes secrets template
├── helm/
│   ├── deploy.sh                           # Helm deployment script
│   └── value_file.yaml                     # Helm chart values
├── operator/
│   ├── install-operator.sh                 # One-time operator installation (runs in container)
│   ├── deploy.sh                           # Operator instance deployment
│   └── subscription.yaml                   # Backstage CR template
├── utils/
│   └── keycloak/
│       ├── keycloak-deploy.sh              # Keycloak deployment script
│       ├── keycloak-values.yaml            # Keycloak Helm values
│       ├── rhdh-client.json               # Keycloak client configuration
│       ├── users.json                     # Test users configuration
│       └── groups.json                    # Groups configuration
├── deploy.sh                               # Main entry point
├── Makefile                                # Make targets
├── OWNERS                                  # Project maintainers
└── README.md                               # This file
```

## Environment Variables

### PR Deployments (Vault Integration)

When using PR deployments, secrets are automatically pulled from vault at:
https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/rhdh-test-instance/

These secrets are available as environment variables with the same name and can be used directly in Kubernetes secrets. From there, they can be referenced in `app-config-rhdh.yaml` or `dynamic-plugins.yaml` configurations.

**Access Requirements:**
- To add or view vault secrets, ensure you have appropriate access
- For access requests, reach out in #team-rhdh slack channel

### Local Deployments (.env Configuration)

For local development, you can add secrets in a `.env` file and use them in your app-config or dynamic plugins configuration.

# Test cluster for rhdh-operator PR #2785 review
