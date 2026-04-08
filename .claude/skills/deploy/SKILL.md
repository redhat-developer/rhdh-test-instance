---
name: deploy
description: This skill should be used when the user asks to "deploy a test instance", "create a test deployment", "deploy RHDH", "spin up a test instance", "deploy with helm", "deploy with operator", "set up a test environment", "create a PR deployment", "use /test deploy", "enable a plugin", "disable a plugin", "add a plugin", "configure a plugin", "list available plugins", "show plugins", "install plugin", "remove plugin", "configure dynamic plugins", "add dynamic plugin", or mentions deploying an RHDH instance or enabling, disabling, or configuring dynamic plugins.
allowed-tools: Bash(gh *), Bash(git *), Bash(oc *), Bash(kubectl *), Bash(*vault*), Bash(curl *), Bash(ls *), Read, Edit, Write, WebFetch
---

# Deploy & Configure RHDH Test Instance

This skill guides users through deploying an RHDH test instance and configuring its dynamic plugins. It covers the full workflow: configuring plugins, deploying via PR, and troubleshooting.

## Part 1: Plugin Configuration

This section helps users enable, disable, and configure dynamic plugins. It uses the [rhdh-plugin-export-overlays](https://github.com/redhat-developer/rhdh-plugin-export-overlays) repository as the authoritative source for available plugins, their packages, and configuration.

### Data Sources

All plugin information comes from the `rhdh-plugin-export-overlays` repo on the `main` branch:

- **Available plugins catalog**: `https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/refs/heads/main/catalog-entities/extensions/plugins/all.yaml`
- **Package metadata (OCI artifact + config examples)**: `https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/workspaces/<plugin-name>/metadata/<package-name>.yaml`

To list all available plugin names:
```bash
curl -s https://api.github.com/repos/redhat-developer/rhdh-plugin-export-overlays/contents/catalog-entities/extensions/plugins | jq -r '.[].name' | sed 's/\.yaml$//'
```

### Workflow: Enabling a Plugin

#### Step 1: Identify the Plugin

- Ask the user which plugin to enable. List all plugins available in the plugins catalog.
- Validate that the plugin name is valid and exists in the plugins catalog. If not try to fetch information for similar plugin names and ask user to select the correct plugin.

#### Step 2: Fetch Plugin Definition

Fetch the plugin definition YAML:
```
curl -s https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/catalog-entities/extensions/plugins/<plugin-name>.yaml
```

From this file, extract:
- `metadata.name` — canonical plugin name
- `metadata.title` — display name
- `spec.packages` — the list of package names that make up this plugin
- `spec.categories` — plugin category

#### Step 3: Fetch Package Metadata

For each package listed in `spec.packages`, fetch its metadata. The metadata files live under `workspaces/<plugin-name>/metadata/`:
```
curl -s https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/workspaces/<plugin-name>/metadata/<package-name>.yaml
```

From each package metadata file, extract:
- `spec.dynamicArtifact` — the OCI image reference (e.g., `oci://ghcr.io/...`)
- `spec.backstage.role` — `frontend-plugin`, `backend-plugin`, or `backend-plugin-module`
- `spec.appConfigExamples` — example configuration snippets
- `spec.partOf` — which plugin(s) this package belongs to

**Important**: Some packages may belong to a different workspace than the plugin name. If a package metadata file is not found under the plugin's workspace, check the package's own workspace (derived from the package name pattern). For example, `backstage-plugin-kubernetes-backend` lives under `workspaces/kubernetes/metadata/`.

#### Step 4: Add Packages to dynamic-plugins.yaml

Edit `config/dynamic-plugins.yaml` to add each package. Three package reference formats exist:

**OCI-based from rhdh-plugin-export-overlays** (most common — use `spec.dynamicArtifact` value):
```yaml
plugins:
  - package: 'oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd:bs_1.45.3__2.4.3!backstage-community-plugin-argocd'
    disabled: false
```

**OCI-based from Red Hat registry** (for Red Hat-shipped plugins):
```yaml
plugins:
  - package: 'oci://registry.access.redhat.com/rhdh/red-hat-developer-hub-backstage-plugin-orchestrator:{{inherit}}'
    disabled: false
```

**Local path** (built-in plugins already bundled):
```yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-community-plugin-catalog-backend-module-keycloak-dynamic
    disabled: false
```

**For packages with frontend plugin configuration** (mount points, translation resources, etc.):
```yaml
plugins:
  - package: 'oci://ghcr.io/...'
    disabled: false
    pluginConfig:
      dynamicPlugins:
        frontend:
          <plugin-config-key>:
            mountPoints:
              - mountPoint: entity.page.overview/cards
                importName: ComponentName
                config:
                  layout:
                    gridColumnEnd:
                      lg: span 8
                      xs: span 12
                  if:
                    allOf:
                      - conditionName
            translationResources:
              - importName: translationImport
                module: ModuleName
                ref: translationRef
```

The `pluginConfig` content comes directly from `spec.appConfigExamples[].content.dynamicPlugins` in the package metadata. Include it exactly as specified. This works only for Operator deployments.

**For packages with dependencies** on other plugins:
```yaml
plugins:
  - package: 'oci://...'
    disabled: false
    dependencies:
      - ref: sonataflow
```

**Common mount points:**

| Mount Point | Location |
|---|---|
| `entity.page.overview/cards` | Entity overview page cards |
| `entity.page.ci/cards` | Entity CI tab cards |
| `entity.page.cd/cards` | Entity CD tab cards |
| `entity.page.kubernetes/cards` | Entity Kubernetes tab cards |
| `entity.page.topology/cards` | Entity Topology tab cards |
| `entity.page.api/cards` | Entity API tab cards |

#### Step 5: Add Backend Configuration (if needed)

If any package metadata includes `spec.appConfigExamples` with backend configuration (anything outside the `dynamicPlugins` key), add that configuration to `config/app-config-rhdh.yaml`.

**Service integration example (ArgoCD):**
```yaml
argocd:
  username: ${ARGOCD_USERNAME}
  password: ${ARGOCD_PASSWORD}
  appLocatorMethods:
    - type: config
      instances:
        - name: argoInstance1
          url: ${ARGOCD_INSTANCE1_URL}
          token: ${ARGOCD_AUTH_TOKEN}
```

**Kubernetes plugin example:**
```yaml
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: ${K8S_CLUSTER_URL}
          name: cluster-name
          authProvider: serviceAccount
          serviceAccountToken: ${K8S_SA_TOKEN}
```

#### Step 6: Add Required Secrets/Environment Variables

If the backend configuration references environment variables (e.g., `${ARGOCD_USERNAME}`), inform the user they need to:
1. Add the actual values to `config/rhdh-secrets.yaml` under `stringData`
2. For PR-based deployments, store secrets in Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`
3. For local deployments, add `export MY_NEW_SECRET="value"` to `.env`

#### Step 7: Present Summary

After making changes, present a summary:
- Which packages were added to `dynamic-plugins.yaml`
- What app-config was added (if any)
- What environment variables/secrets need to be set (if any)
- Remind the user to deploy or redeploy the instance for changes to take effect

### Workflow: Disabling a Plugin

1. Read `config/dynamic-plugins.yaml`
2. Find the package entries for the plugin
3. Either set `disabled: true` or remove the entries entirely
4. If removing, also clean up any related configuration from `config/app-config-rhdh.yaml`

### Workflow: Checking Current Plugin Configuration

1. Read `config/dynamic-plugins.yaml` to show currently enabled plugins
2. Cross-reference with the plugin catalog to identify plugin names

### Plugin Configuration Notes

- **Package names vs plugin names**: A single plugin (e.g., `argocd`) consists of multiple packages (e.g., `backstage-community-plugin-redhat-argocd` frontend + `backstage-community-plugin-redhat-argocd-backend`). ALL packages for a plugin must be enabled together.
- **OCI references**: Always use the `spec.dynamicArtifact` value from the package metadata as the package reference. Do not construct OCI references manually.
- **Frontend plugin config**: Frontend plugins typically require `pluginConfig` with mount points and other UI wiring. Always include the config from `appConfigExamples`.
- **`{{inherit}}`**: Some older plugins use `{{inherit}}` in their OCI reference — this is a special marker for the Red Hat registry. For plugins from the export-overlays repo, always use the full OCI reference from `spec.dynamicArtifact`.
- **Order matters**: Backend plugins should generally be listed before their corresponding frontend plugins in `dynamic-plugins.yaml`.

---

## Part 2: Deployment

This section guides users through deploying an RHDH test instance via the GitHub PR workflow. The primary deployment method is opening a PR on the `rhdh-test-instance` repo and using the `/test deploy` slash command in PR comments. Prow CI handles provisioning, Keycloak auth setup, and RHDH installation automatically.

### Configuration Files

| File | Purpose |
|---|---|
| `config/app-config-rhdh.yaml` | RHDH app config (auth, catalog, providers, backend plugin config). Applied as a ConfigMap. |
| `config/dynamic-plugins.yaml` | Plugin enablement — lists packages to load and their configuration. Includes `dynamic-plugins.default.yaml` for defaults. |
| `config/rhdh-secrets.yaml` | Kubernetes Secret template with env vars. Variables substituted at deploy time. |
| `config/orchestrator-dynamic-plugins.yaml` | Orchestrator plugins, auto-merged when `ORCH=true`. Do not manually merge. |
| `helm/value_file.yaml` | Helm chart value overrides (resource limits, replicas, etc.) |
| `operator/subscription.yaml` | Backstage CR for operator deployments |

#### app-config-rhdh.yaml Structure

```yaml
app:
  baseUrl: "${RHDH_BASE_URL}"          # Auto-set by deploy scripts
auth:
  environment: production
  providers:
    oidc:                               # Keycloak OIDC provider (auto-configured)
      production:
        metadataUrl: "${KEYCLOAK_METADATA_URL}"
        clientId: "${KEYCLOAK_CLIENT_ID}"
        clientSecret: "${KEYCLOAK_CLIENT_SECRET}"
catalog:
  locations:                            # Entity sources — most common customization
    - type: url
      target: https://github.com/redhat-developer/rhdh/blob/main/catalog-entities/all.yaml
  providers:
    keycloakOrg:                        # Syncs users/groups from Keycloak (auto-configured)
      default:
        baseUrl: "${KEYCLOAK_BASE_URL}"
        realm: "${KEYCLOAK_REALM}"
```

All `${VAR}` placeholders are substituted at runtime. Variables come from: Keycloak deploy script (auto-set: `KEYCLOAK_*`, `RHDH_BASE_URL`), Vault secrets (PR deployments), or `.env` file (local deployments). To add a new variable: define it in `config/rhdh-secrets.yaml`, then reference it in app-config as `${VAR_NAME}`.

#### Common app-config Modifications

**Add a catalog location** (most common):
```yaml
catalog:
  locations:
    - type: url
      target: https://github.com/my-org/my-repo/blob/main/catalog-info.yaml
```

**Add a new auth provider alongside OIDC:**
```yaml
auth:
  providers:
    oidc: ...           # existing
    github:
      production:
        clientId: "${GITHUB_CLIENT_ID}"
        clientSecret: "${GITHUB_CLIENT_SECRET}"
```

**Add a new catalog provider:**
```yaml
catalog:
  providers:
    github:
      myOrg:
        organization: my-org
        schedule:
          frequency: { minutes: 30 }
          timeout: { minutes: 3 }
```

#### helm/value_file.yaml Structure

Minimal by default — most configuration goes through `app-config-rhdh.yaml` via the ConfigMap.

```yaml
upstream:
  backstage:
    extraAppConfig:
      - configMapRef: app-config-rhdh
        filename: app-config-rhdh.yaml
    extraEnvVarsSecrets:
      - rhdh-secrets
```

To customize Helm-specific values (resource limits, replicas, etc.), add under the `upstream` key following the RHDH Helm chart schema.

#### operator/subscription.yaml Key Fields

- `spec.application.appConfig.configMapRef` — references the app-config ConfigMap
- `spec.application.dynamicPluginsConfigMapName` — references the dynamic plugins ConfigMap
- `spec.database.enableLocalDb` — uses a local PostgreSQL database
- `spec.application.route.enabled` — creates an OpenShift Route

### Deployment Workflow

#### Step 1: Determine Configuration Needs

Ask the user:

1. **Install type** — `helm` or `operator`
2. **RHDH version** — semantic (e.g. `1.9`), CI build (e.g. `1.9-190-CI`), or `next`
3. **Duration** — how long the instance should stay up (default: `3h`, e.g. `4h`, `2.5h`)
4. **Custom configuration** — whether they need non-default app-config, plugins, or secrets

If the user does not need custom configuration, skip to Step 3.

#### Step 2: Prepare Custom Configuration (if needed)

If the user needs custom configuration, create a new branch and make changes to the relevant files listed in the Configuration Files table above.

Common customizations:

- **Adding catalog locations** — add entries under `catalog.locations` in `app-config-rhdh.yaml`
- **Enabling plugins** — use the Plugin Configuration workflow in Part 1
- **Adding secrets/env vars** — add to `config/rhdh-secrets.yaml` and reference in app-config via `${VAR_NAME}`; for PR deployments, the actual secret values must be stored in Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`

After making changes, commit and push the branch, then open a PR.

#### Step 3: Create the PR

If no custom config is needed, create a minimal PR (e.g. an empty commit or a small README change) to get a PR number for the `/test` command.

Use `gh` CLI to create the PR:

```bash
git checkout -b <branch-name>
git commit --allow-empty -m "Deploy test instance"
git push -u origin <branch-name>
gh pr create --title "Deploy RHDH <version> test instance" --body "Deploying RHDH test instance for testing."
```

#### Step 4: Trigger Deployment

Post a comment on the PR with the deploy command:

```
/test deploy <install-type> <version> [duration]
```

Examples:
```
/test deploy helm 1.9 4h
/test deploy operator 1.7 2.5h
/test deploy helm 1.9-190-CI
/test deploy helm next
```

Parameters:
- `install-type`: `helm` or `operator`
- `version`: `1.9`, `1.9-190-CI`, `next`, etc.
- `duration`: optional cleanup timer (default `3h`)

#### Step 5: Monitor and Share Results

After posting the deploy command, poll for the `@rhdh-test-bot` comment. Deployments typically take 10–20 minutes.

Run a background polling loop with `run_in_background: true` and `timeout: 600000` (10 min). If it times out without a bot comment, start a second polling loop (another 10 min) to cover the full 20-minute window.

```bash
while true; do
  comment=$(gh pr view <PR_NUMBER> --comments --json comments \
    --jq '.comments[] | select(.author.login == "rhdh-test-bot") | .body' 2>/dev/null)
  if [ -n "$comment" ]; then
    echo "$comment"
    break
  fi
  sleep 30
done
```

Once the bot comments:

1. On success, the comment contains the RHDH URL, OpenShift Console link, cluster credentials (from Vault), and instance availability window
2. Present the deployment details to the user
3. Share the RHDH URL and credentials from the bot's PR comment with anyone who needs access

### Constraints

- Maximum **two concurrent** test instances
- Default duration is **3 hours** if not specified
- Test users for login: `test1` / `test1@123` or `test2` / `test2@123`

---

## Troubleshooting

If the deployed RHDH instance is not starting (readiness probe failing, pod not becoming ready), log in to the OpenShift cluster and inspect logs.

### Handling Secrets

**CRITICAL: Never let secret values appear in tool outputs.** When running commands that involve credentials from Vault, always use bash subshells or piping so that secret values are passed directly between commands and never printed or captured in the response. The LLM model must not see secret values.

**Correct** — secrets stay inside the shell, never visible to the model:
```bash
oc login https://api.<cluster>:6443 \
  -u $(VAULT_ADDR=https://vault.ci.openshift.org vault kv get -field=CLUSTER_ADMIN_USERNAME kv/selfservice/rhdh-test-instance/ocp-cluster-creds) \
  -p $(VAULT_ADDR=https://vault.ci.openshift.org vault kv get -field=CLUSTER_ADMIN_PASSWORD kv/selfservice/rhdh-test-instance/ocp-cluster-creds) \
  --insecure-skip-tls-verify
```

**Wrong** — fetching credentials into a variable or printing them exposes secrets to the model:
```bash
# DO NOT do this — secrets will appear in the tool output
PASSWORD=$(vault kv get -field=CLUSTER_ADMIN_PASSWORD ...)
echo $PASSWORD
oc login -u admin -p "$PASSWORD" ...
```

### Logging in to the Cluster

Use `oc` if available, otherwise fall back to `kubectl`. Check with `which oc || which kubectl`.

The cluster API URL can be derived from the bot comment's OpenShift Console URL by replacing `console-openshift-console.apps.` with `api.` and appending port `:6443`.

Example: if the console URL is `https://console-openshift-console.apps.rhdh-4-18-us-east-2-q5h5x.rhdh-qe.devcluster.openshift.com`, the API URL is `https://api.rhdh-4-18-us-east-2-q5h5x.rhdh-qe.devcluster.openshift.com:6443`.

Credentials are stored in Vault at `kv/selfservice/rhdh-test-instance/ocp-cluster-creds` with keys `CLUSTER_ADMIN_USERNAME` and `CLUSTER_ADMIN_PASSWORD`.

**With `oc`:**
```bash
oc login https://api.<cluster>:6443 \
  -u $(VAULT_ADDR=https://vault.ci.openshift.org vault kv get -field=CLUSTER_ADMIN_USERNAME kv/selfservice/rhdh-test-instance/ocp-cluster-creds) \
  -p $(VAULT_ADDR=https://vault.ci.openshift.org vault kv get -field=CLUSTER_ADMIN_PASSWORD kv/selfservice/rhdh-test-instance/ocp-cluster-creds) \
  --insecure-skip-tls-verify
```

**With `kubectl`** (when `oc` is not available):
```bash
kubectl config set-cluster rhdh-test --server=https://api.<cluster>:6443 --insecure-skip-tls-verify=true && \
kubectl config set-credentials rhdh-test \
  --username=$(VAULT_ADDR=https://vault.ci.openshift.org vault kv get -field=CLUSTER_ADMIN_USERNAME kv/selfservice/rhdh-test-instance/ocp-cluster-creds) \
  --password=$(VAULT_ADDR=https://vault.ci.openshift.org vault kv get -field=CLUSTER_ADMIN_PASSWORD kv/selfservice/rhdh-test-instance/ocp-cluster-creds) && \
kubectl config set-context rhdh-test --cluster=rhdh-test --user=rhdh-test && \
kubectl config use-context rhdh-test
```

### Debugging Steps

Use `oc` or `kubectl` interchangeably in all commands below.

1. **Check pod status**: `oc get pods -n rhdh`
2. **Check events**: `oc get events -n rhdh --sort-by='.lastTimestamp' | tail -30`
3. **Check init container logs** (plugin installation): `oc logs -n rhdh <pod-name> -c install-dynamic-plugins --tail=50`
4. **Check backend logs for errors**: `oc logs -n rhdh <pod-name> -c backstage-backend 2>&1 | grep -i -E 'error|fail|exception' | head -40`

### Common Issues

- **Missing environment variables**: Backend plugin modules may require config values (e.g., `jira.baseUrl`) backed by env vars that aren't set. Fix: either add the secrets to Vault and `rhdh-secrets.yaml`, or disable the module that requires them.
- **Plugin initialization failure**: One failing plugin module can block the entire RHDH startup. Check logs for `threw an error during startup` messages to identify which module is failing.
