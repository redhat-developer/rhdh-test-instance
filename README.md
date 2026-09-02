# RHDH Test Instance

A comprehensive test instance setup for **Red Hat Developer Hub (RHDH)** on OpenShift, providing a ready-to-use developer portal with authentication, app-config, and dynamic plugin config.

## Overview

This project provides automated deployment scripts and configuration files to set up a fully functional RHDH test instance on OpenShift.

### Features

- 🤖 **GitHub PR Integration** with `/test` command for on-demand deployments
- 📦 **Multiple Install Types**: Support for both Helm and Operator installation methods
- 🔄 **Flexible Version Support**: Deploy any RHDH version (latest, semantic versions like 1.7, CI builds like 1.7-98-CI)
- 🌐 **Cluster Information Sharing**: Automatic sharing of deployment URLs, OpenShift console access, and cluster credentials
- 🔐 **Flexible Authentication**: Guest login by default; optional Keycloak OIDC via `--plugins keycloak`
- 👥 **Runtime Test Users**: Keycloak test users provisioned with a generated password stored in a cluster Secret
- 🏠 **Local Deployment**: Support for local development and testing environments
- ⚡ **Resource Management**: Automatic cleanup with configurable timers and resource limits
- 🎯 **Instance Limits**: Maximum of two concurrent test instances to manage resource usage
- 💬 **User-friendly feedback** with deployment status comments and live URLs
- 🛠️ **Debug & Customization Support**: Shared cluster credentials for troubleshooting and custom configurations

## GitHub PR Workflow Integration

Deploy test environments directly from Pull Requests using slash commands and test different configurations without local setup.

### Slash Commands

The bot supports flexible deployment commands directly from PR comments:

```bash
/test deploy <install-type> <version> [duration]
```

**Parameters:**

- `install-type`: `helm` or `operator`
- `version`: Version to deploy (see supported versions below)
- `duration`: Optional cleanup timer (e.g., `4h`, `2.5h`)

**Examples:**

```bash
/test deploy helm 1.7 4h          # Deploy RHDH 1.7 with Helm, cleanup after 4 hours
/test deploy operator 1.6 2.5h     # Deploy RHDH 1.6 with Operator, cleanup after 2.5 hours
/test deploy helm 1.7            # Deploy latest CI version with Helm with defaut duration 3h
/test deploy operator 1.7-98-CI   # Deploy specific CI build with Operator
```

### How to Use PR Integration

1. **Comment on any PR on rhdh-test-instance repo:**

   ```bash
   /test deploy helm 1.7 4h
   ```

### Feedback Loop

The bot provides comprehensive feedback through PR comments for eg:

```text
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
<https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy>

**Job History:**
<https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-redhat-developer-rhdh-test-instance-main-deploy>

### Testing Custom Configurations via PRs

Users can deploy different configuration flavors by:

1. **Creating a PR** with modified configuration files
2. **Using bot commands** to deploy the PR's configuration:

   ```bash
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
- `.env` file configured (copy from `.env.example`) — only needed if using Vault-based secrets locally

### Quick Start

1. **Clone the repository:**

   ```bash
   git clone <repository-url>
   cd rhdh-test-instance
   ```

2. **Configure environment (optional):**

   ```bash
   cp .env.example .env
   # Only needed for Vault-based local secrets
   ```

3. **Deploy RHDH:**

   ```bash
   make deploy-helm VERSION=1.9-190-CI                          # Guest auth (default)
   make deploy-helm VERSION=1.9-190-CI PLUGINS=keycloak         # With Keycloak OIDC
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
# Remove RHDH only (leave Keycloak/Lighthouse in place)
make undeploy-helm
make undeploy-operator

# Remove RHDH and tear down plugin infrastructure
make undeploy-helm PLUGINS=keycloak,lighthouse
make undeploy-operator PLUGINS=keycloak

# Tear down plugin infra only, leave RHDH running
make undeploy-plugins PLUGINS=keycloak,lighthouse
make undeploy-plugins PLUGINS=lighthouse

# Remove orchestrator infra chart
make undeploy-infra

# Delete the entire namespace (removes everything)
make clean
```

#### OSL RC smoke

Pin an OSL pre-release against a chosen RHDH version, deploy, and run the default four Playwright tests (skips `orchestrator.spec.ts` beforeAll so it does not reinstall operators):

1. `Run Greeting workflow and verify Workflows tab`
2. `Run Failswitch workflow and verify statuses`
3. `Rerun Failswitch from failure point`
4. `Execute token-propagation workflow via API`

Smoke always deploys greeting, failswitch, token-propagation, and `sample-server`, then runs token-propagation (JWT/OpenAPI into the workflow). Overlays orchestrator e2e is **NFS-only** (`orchestrator-app-next`): `--test` requires `--namespace` to match that Playwright project (default `orchestrator-app-next`). Deploying `next` / `*-CI` always enables the app-next shell (`APP_CONFIG_app_packageName=app-next` + `ENABLE_STANDARD_MODULE_FEDERATION` on `rhdh-secrets`). Point `--overlays-dir` at an overlays checkout that includes the NFS lane. `--cleanup` (and the cleanup phase of `--all`) always removes OSL/Serverless operators (`logic-operator` / `serverless-operator` only), the custom catalog, and the mirror namespace, and cleans the RHDH namespace contents. It does not delete a leftover `rhdh` namespace unless you pass `--delete-namespace` (`make cleanup-full`). Other operators in `openshift-operators` are left in place.

`make setup-orchestrator` (and the driver's `--deploy` phase) installs `osl-di-rewrite` in front of Data Index so OSL 1.39 relative `serviceUrl` values still work from RHDH. The GraphQL probe before Playwright hits that rewrite proxy (`osl-di-rewrite`), not raw Data Index. OSL 1.39.CR1 can return a relative `ProcessDefinitions.serviceUrl` (SRVLOGIC-1137); the rewrite fills `serviceUrl` from `endpoint`. If the probe still sees a relative URL, it exits 2 unless you pass `--allow-relative-service-url` or `ALLOW_RELATIVE_SERVICE_URL=1`. Drop that override after the Orchestrator plugin derives `serviceUrl` from `endpoint`.

```bash
# One-shot: full cleanup (including operators) -> mirror OSL -> deploy -> smoke
make osl-regression VERSION=next OSL_RELEASE=1.39.0.CR1 ORCH_NAMESPACE=orchestrator-app-next

# Or call the driver directly
./run-osl-regression.sh --all --rhdh next --osl-release 1.39.0.CR1
./run-osl-regression.sh --cleanup --namespace orchestrator-app-next
./run-osl-regression.sh --cleanup --prepare-osl --deploy --rhdh next --osl-release 1.39.0.CR1
./run-osl-regression.sh --test --rhdh next
./run-osl-regression.sh --test --rhdh next --overlays-dir ../rhdh-plugin-export-overlays
```

Individual pieces:

```bash
make prepare-osl OSL_RELEASE=1.39.0.CR1
make setup-orchestrator VERSION=next ORCH_NAMESPACE=orchestrator-app-next OSL_RELEASE=1.39.0.CR1
make cleanup-full ORCH_NAMESPACE=orchestrator-app-next
```

Requires `oc` logged in, `helm`, `skopeo`, `podman`, and a sibling `rhdh-plugin-export-overlays` checkout for `--test` (NFS `orchestrator-app-next` project). Manifests live in `config/osl-releases/`.

#### Status and Debugging

```bash
make status                           # Pods, helm releases, operator versions
make logs                             # Tail RHDH pod logs
make url                              # Print RHDH URL
```

#### Variables

All make commands accept these variables:

| Variable            | Default                                       | Description                                                               |
| ------------------- | --------------------------------------------- | ------------------------------------------------------------------------- |
| `NAMESPACE`         | `rhdh`                                        | Target namespace                                                          |
| `VERSION`           | `1.9`                                         | RHDH version (`1.9`, `1.9-190-CI`, or `next`)                             |
| `ORCH`              | `false`                                       | Set to `true` to deploy with orchestrator support                         |
| `PLUGINS`           | _(empty)_                                     | Comma-separated plugins to deploy/teardown (e.g. `keycloak,lighthouse`)   |
| `USE_CONTAINER`     | `false`                                       | Set to `true` to run commands inside the e2e-runner container             |
| `CATALOG_INDEX_TAG` | auto                                          | Catalog index image tag (defaults to major.minor from version, or `next`) |
| `RUNNER_IMAGE`      | `quay.io/rhdh-community/rhdh-e2e-runner:main` | Container image for `install-operator`                                    |
| `OSL_RELEASE`       | _(empty)_                                     | OSL pre-release id for `prepare-osl` / `osl-regression`                   |
| `ORCH_NAMESPACE`    | `orchestrator-app-next`                       | Namespace used by orchestrator/OSL setup and cleanup (NFS Playwright project) |
| `ALLOW_RELATIVE_SERVICE_URL` | _(unset)_                          | Set to `1` to continue smoke if the rewrite probe still sees a relative `serviceUrl` |

> **Note:** `install-operator` requires you to be logged into the cluster via `oc login` on your host.
> It automatically passes the session token to the e2e-runner container (needs Linux tools like `umoci`, `opm`, `skopeo`).
> The operator is installed once per cluster. After that, `deploy-operator` runs locally like `deploy-helm`.

### Direct Script Usage

You can also use `deploy.sh` and `teardown.sh` directly:

**Deploy:**

```bash
./deploy.sh <install-method> <version> [--namespace <ns>] [--with-orchestrator] [--plugins <list>]
```

```bash
./deploy.sh helm 1.9
./deploy.sh helm 1.9-190-CI
./deploy.sh helm next
./deploy.sh helm 1.9 --namespace rhdh-helm --with-orchestrator
./deploy.sh helm 1.9 --plugins keycloak,lighthouse
./deploy.sh operator 1.9 --namespace rhdh-operator
./deploy.sh operator next --with-orchestrator
```

**Teardown:**

```bash
./teardown.sh <install-method> [--namespace <ns>] [--plugins <list>] [--clean]
```

```bash
./teardown.sh helm                                              # Remove RHDH only
./teardown.sh helm --plugins keycloak,lighthouse               # Remove RHDH + plugin infra
./teardown.sh helm --namespace rhdh-helm --plugins keycloak    # Remove from non-default namespace
./teardown.sh operator --plugins keycloak,lighthouse
./teardown.sh helm --clean                                      # Full wipe: delete entire namespace
./teardown.sh helm --plugins keycloak,lighthouse --clean        # Teardown plugins then delete namespace
```

> **Note:** `--clean` deletes the entire namespace after teardown, removing all resources including image streams. Omit it when redeploying to the same namespace to preserve cached image streams and avoid registry rate limits.

### Accessing Your Local RHDH Instance

After successful installation, access your RHDH instance at:

```text
https://redhat-developer-hub-<namespace>.<cluster-router-base>
```

### Login Process

1. Navigate to the RHDH URL (`make url` to print it)
2. Click **Sign In**
3. **Guest auth** (default): click **Enter** to sign in as `guest`
4. **Keycloak auth** (when `--plugins keycloak` was used): sign in with any test user defined in `resources/keycloak/users.json` — see [Finding Keycloak Credentials](#finding-keycloak-credentials) below

## Configuration

### Application Configuration

The main application configuration is stored in `config/app-config-rhdh.yaml`:

```yaml
app:
  baseUrl: '${RHDH_BASE_URL}'

auth:
  environment: production
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
signInPage: guest

catalog:
  locations:
    - type: url
      target: https://github.com/redhat-developer/rhdh/blob/main/catalog-entities/all.yaml
```

When the `keycloak` plugin is enabled, an additional `pluginConfig` block within the Keycloak `dynamic-plugins.yaml` overlay switches authentication to OIDC, overriding the base guest config.

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

## Authentication

### Default: Guest Login

By default, RHDH is configured with the Guest provider so you can sign in immediately without any additional setup. A `guest` user entity is pre-registered in the catalog.

### Optional: Keycloak OIDC

When you deploy with `--plugins keycloak`, Keycloak is automatically set up with an OIDC client and the sign-in page switches to OIDC. Test users and groups are created from `resources/keycloak/users.json` and `resources/keycloak/groups.json`.

- **Realm**: `rhdh`
- **Client ID**: `rhdh-client`
- **Test user password**: randomly generated at deploy time (see below)

### Finding Keycloak Credentials

After a successful Keycloak deployment, credentials are stored in a cluster Secret and also printed to the deploy log.

**Via `oc`:**

```bash
# Print all credentials
oc get secret keycloak-test-credentials -n rhdh -o jsonpath='{.data}' | \
  jq 'to_entries[] | "\(.key): \(.value | @base64d)"' -r

# Print only the shared user password
oc get secret keycloak-test-credentials -n rhdh \
  -o jsonpath='{.data.KEYCLOAK_USER_PASSWORD}' | base64 -d && echo

# Print the username list
oc get secret keycloak-test-credentials -n rhdh \
  -o jsonpath='{.data.KEYCLOAK_USERNAMES}' | base64 -d && echo
```

**Via OpenShift Console:**

Navigate to **Workloads > Secrets > `keycloak-test-credentials`** in your namespace and click **Reveal values**.

**Secret keys:**

| Key | Description |
|---|---|
| `KEYCLOAK_URL` | Keycloak base URL |
| `KEYCLOAK_USERNAMES` | Comma-separated list of all test usernames (read from `users.json` at deploy time) |
| `KEYCLOAK_USER_PASSWORD` | Shared password for all test users (generated at runtime — not hardcoded) |

**Admin credentials** are stored by the Bitnami Helm chart itself in the `keycloak-keycloak` Secret in the same namespace:

```bash
oc get secret keycloak-keycloak -n rhdh \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

## Project Structure

```directory
rhdh-test-instance/
├── config/
│   ├── app-config-rhdh.yaml                # Main RHDH configuration (guest auth by default)
│   ├── dynamic-plugins.yaml                # Base dynamic plugins configuration
│   ├── orchestrator-dynamic-plugins.yaml   # Orchestrator plugins (merged when ORCH=true)
│   ├── orchestrator-dynamic-plugins-next.yaml # next/CI: NFS PluginRoot + OIDC auth module
│   ├── osl-releases/                       # Local OSL pre-release JSON (gitignored except example)
│   ├── rbac-policies.yaml                  # RBAC policy ConfigMap
│   └── rhdh-secrets.yaml                   # Reference template for rhdh-secrets Secret
├── helm/
│   ├── deploy.sh                           # Helm deployment script
│   └── value_file.yaml                     # Helm chart values
├── operator/
│   ├── install-operator.sh                 # One-time operator installation (runs in container)
│   ├── deploy.sh                           # Operator instance deployment
│   └── subscription.yaml                   # Backstage CR template
├── resources/
│   ├── catalog-entities/                   # Catalog entity ConfigMaps (applied unconditionally)
│   │   ├── components.yaml
│   │   ├── operators.yaml
│   │   ├── plugins.yaml
│   │   ├── resources.yaml
│   │   └── users.yaml                      # guest user entity
│   ├── image-stream-imports/               # Pre-import images to avoid rate limits
│   ├── keycloak/                           # Keycloak plugin resources and config
│   ├── lighthouse/                         # Lighthouse plugin resources and config
│   └── rhdh-script-examples/              # Demo workloads for Topology/Kubernetes views
├── scripts/
│   ├── config-plugins.sh                   # Plugin orchestration (round-robin setup/teardown)
│   ├── setup-resources.sh                  # Shared cluster resource provisioning/teardown
│   └── plugins/
│       ├── config-keycloak-plugin.sh       # Keycloak deploy, realm/client/user setup
│       └── config-lighthouse-plugin.sh     # Lighthouse deploy and URL injection
├── utils/
│   ├── shell/
│   │   ├── common.sh                       # log, die, require_cmd
│   │   ├── openshift.sh                    # oc login, namespace validation, route helpers
│   │   └── workspace.sh                    # resolve_workspace_dir
│   ├── keycloak/
│   │   ├── lib.sh                          # Shared Keycloak REST + runtime env helpers
│   │   ├── keycloak-deploy.sh
│   │   └── update-rhdh-client-redirects.sh
│   └── orchestrator/
│       ├── assert-osl-operators.sh         # OSL operator subscription/CSV asserts
│       ├── probe-dataindex-rewrite.sh      # Data Index GraphQL probe via osl-di-rewrite
│       └── deploy-smoke-workflows.sh
├── cleanup.sh                              # Orchestrator/OSL teardown (operators optional)
├── deploy.sh                               # Main deploy entry point
├── prepare-osl-internal.sh                 # Mirror pre-release OSL into the internal registry
├── run-osl-regression.sh                   # OSL RC smoke driver (cleanup → prepare → deploy → test)
├── setup-orchestrator.sh                   # RHDH + orchestrator + Keycloak + rewrite proxy
├── teardown.sh                             # Main teardown entry point
├── Makefile                                # Make targets
├── OWNERS                                  # Project maintainers
└── README.md                               # This file
```

## Environment Variables

### PR Deployments (Vault Integration)

When using PR deployments, secrets are automatically pulled from vault at:
<https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/rhdh-test-instance/>

These secrets are available as environment variables with the same name and can be used directly in Kubernetes secrets. From there, they can be referenced in `app-config-rhdh.yaml` or `dynamic-plugins.yaml` configurations.

**Access Requirements:**

- To add or view vault secrets, ensure you have appropriate access
- For access requests, reach out in #team-rhdh slack channel

### Local Deployments (.env Configuration)

For local development, you can add secrets in a `.env` file and use them in your app-config or dynamic plugins configuration.
