---
name: configure-plugins
description: This skill should be used when the user asks to "enable a plugin", "disable a plugin", "add a plugin", "configure a plugin", "list available plugins", "show plugins", "install plugin", "remove plugin", "configure dynamic plugins", "add dynamic plugin", or mentions enabling, disabling, or configuring dynamic plugins in the RHDH test instance.
allowed-tools: Bash(curl *), Bash(ls *), Bash(git *), Read, Edit, Write, WebFetch
---

# Configure Dynamic Plugins

This skill helps users enable, disable, and configure dynamic plugins in the RHDH test instance. It uses the [rhdh-plugin-export-overlays](https://github.com/redhat-developer/rhdh-plugin-export-overlays) repository as the authoritative source for available plugins, their packages, and configuration.

## Data Sources

All plugin information comes from the `rhdh-plugin-export-overlays` repo on the `main` branch:

- **Available plugins catalog**: `https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/refs/heads/main/catalog-entities/extensions/plugins/all.yaml`
- **Package metadata (OCI artifact + config examples)**: `https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/workspaces/<plugin-name>/metadata/<package-name>.yaml`

## Local Configuration Files

| File | What it controls |
|---|---|
| `config/dynamic-plugins.yaml` | Plugin enablement — lists packages to load and their configuration |
| `config/rhdh-secrets.yaml` | Environment variables/secrets referenced by plugins |

## Workflow: Enabling and configuring a Plugin

### Step 1: Identify the Plugin

- Ask the user which plugin to enable. The plugin name corresponds to the YAML filename in the plugins catalog (e.g., `argocd`, `tekton`, `keycloak`, `jenkins`).
- Validate that the plugin name is valid and exists in the plugins catalog. If not try to fetch information for similar plugin names and ask user to select the correct plugin.


### Step 2: Fetch Plugin Definition

Fetch the plugin definition YAML:
```
curl -s https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/catalog-entities/extensions/plugins/<plugin-name>.yaml
```

From this file, extract `spec.packages` — the list of package names that make up this plugin.

### Step 3: Fetch Package Metadata

For each package listed in `spec.packages`, fetch its metadata. The metadata files live under `workspaces/<plugin-name>/metadata/`:
```
curl -s https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/workspaces/<plugin-name>/metadata/<package-name>.yaml
```

From each package metadata file, extract:
- `spec.dynamicArtifact` — the OCI image reference (e.g., `oci://ghcr.io/...`)
- `spec.backstage.role` — `frontend-plugin`, `backend-plugin`, or `backend-plugin-module`
- `spec.appConfigExamples` — example configuration snippets

**Important**: Some packages may belong to a different workspace than the plugin name. If a package metadata file is not found under the plugin's workspace, check the package's own workspace (derived from the package name pattern). For example, `backstage-plugin-kubernetes-backend` lives under `workspaces/kubernetes/metadata/`.

### Step 4: Add Packages to dynamic-plugins.yaml

Edit `config/dynamic-plugins.yaml` to add each package. The format depends on the package type:

**For OCI-based packages** (most common):
```yaml
plugins:
  - package: '<dynamicArtifact value>'
    disabled: false
```

**For packages with plugin configuration** (frontend plugins with mount points, translation resources, etc.):
```yaml
plugins:
  - package: '<dynamicArtifact value>'
    disabled: false
    pluginConfig:
      dynamicPlugins:
        frontend:
          <plugin-config-key>:
            mountPoints:
              - mountPoint: <mount-point>
                importName: <import-name>
                config:
                  layout: <layout-config>
                  if:
                    allOf:
                      - <condition>
```

The `pluginConfig` content comes directly from `spec.appConfigExamples[].content.dynamicPlugins` in the package metadata. Include it exactly as specified.

### Step 5: Add Backend Configuration (if needed)

If any package metadata includes `spec.appConfigExamples` with backend configuration (anything outside the `dynamicPlugins` key), add that configuration to `config/app-config-rhdh.yaml`.

For example, the ArgoCD backend needs:
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

### Step 6: Add Required Secrets/Environment Variables

If the backend configuration references environment variables (e.g., `${ARGOCD_USERNAME}`), inform the user they need to:
1. Add the actual values to `config/rhdh-secrets.yaml`
2. For PR-based deployments, store secrets in Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`

### Step 7: Present Summary

After making changes, present a summary:
- Which packages were added to `dynamic-plugins.yaml`
- What app-config was added (if any)
- What environment variables/secrets need to be set (if any)
- Remind the user to deploy or redeploy the instance for changes to take effect

## Workflow: Disabling a Plugin

1. Read `config/dynamic-plugins.yaml`
2. Find the package entries for the plugin
3. Either set `disabled: true` or remove the entries entirely
4. If removing, also clean up any related configuration from `config/app-config-rhdh.yaml`

## Workflow: Checking Current Plugin Configuration

1. Read `config/dynamic-plugins.yaml` to show currently enabled plugins
2. Cross-reference with the plugin catalog to identify plugin names

## Important Notes

- **Package names vs plugin names**: A single plugin (e.g., `argocd`) consists of multiple packages (e.g., `backstage-community-plugin-redhat-argocd` frontend + `backstage-community-plugin-redhat-argocd-backend`). ALL packages for a plugin must be enabled together.
- **OCI references**: Always use the `spec.dynamicArtifact` value from the package metadata as the package reference. Do not construct OCI references manually.
- **Frontend plugin config**: Frontend plugins typically require `pluginConfig` with mount points and other UI wiring. Always include the config from `appConfigExamples`.
- **`{{inherit}}`**: Some older plugins use `{{inherit}}` in their OCI reference — this is a special marker for the Red Hat registry. For plugins from the export-overlays repo, always use the full OCI reference from `spec.dynamicArtifact`.
- **Order matters**: Backend plugins should generally be listed before their corresponding frontend plugins in `dynamic-plugins.yaml`.

## Reference Files

- **`references/plugin-config-format.md`** — detailed format reference for `dynamic-plugins.yaml` entries
