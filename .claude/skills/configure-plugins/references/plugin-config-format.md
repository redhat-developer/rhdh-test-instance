# Dynamic Plugin Configuration Format Reference

## dynamic-plugins.yaml Structure

The `config/dynamic-plugins.yaml` file controls which dynamic plugins are loaded. It has two top-level keys:

```yaml
includes:
  - dynamic-plugins.default.yaml   # includes the default plugin set shipped with RHDH

plugins:
  # custom plugin entries go here
  - package: <package-reference>
    disabled: false
```

### Package Reference Formats

**OCI-based (from rhdh-plugin-export-overlays):**
```yaml
- package: 'oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd:bs_1.45.3__2.4.3!backstage-community-plugin-argocd'
  disabled: false
```

**OCI-based (from Red Hat registry):**
```yaml
- package: 'oci://registry.access.redhat.com/rhdh/red-hat-developer-hub-backstage-plugin-orchestrator:{{inherit}}'
  disabled: false
```

**Local path (built-in plugins):**
```yaml
- package: ./dynamic-plugins/dist/backstage-community-plugin-catalog-backend-module-keycloak-dynamic
  disabled: false
```

### Plugin Configuration (pluginConfig)

Frontend plugins often need UI wiring configuration via `pluginConfig`:

```yaml
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

### Dependencies

Some plugins depend on other plugins being enabled:

```yaml
- package: 'oci://...'
  disabled: false
  dependencies:
    - ref: sonataflow
```

### Common Mount Points

| Mount Point | Location |
|---|---|
| `entity.page.overview/cards` | Entity overview page cards |
| `entity.page.ci/cards` | Entity CI tab cards |
| `entity.page.cd/cards` | Entity CD tab cards |
| `entity.page.kubernetes/cards` | Entity Kubernetes tab cards |
| `entity.page.topology/cards` | Entity Topology tab cards |
| `entity.page.api/cards` | Entity API tab cards |

## app-config-rhdh.yaml Backend Plugin Configuration

Backend plugins typically need configuration in `config/app-config-rhdh.yaml`. Common patterns:

### Service Integration (ArgoCD example)
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

### Kubernetes Plugin
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

## rhdh-secrets.yaml Environment Variables

Secrets and environment variables are defined in `config/rhdh-secrets.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rhdh-secrets
type: Opaque
stringData:
  RHDH_BASE_URL: ""
  # Add plugin-specific variables here:
  ARGOCD_USERNAME: ""
  ARGOCD_PASSWORD: ""
```

For PR-based deployments, actual values must be stored in Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`.

## Plugin Data Source Reference

### Fetching the Plugin Catalog List

```bash
curl -s https://api.github.com/repos/redhat-developer/rhdh-plugin-export-overlays/contents/catalog-entities/extensions/plugins | jq -r '.[].name' | sed 's/\.yaml$//'
```

### Fetching a Plugin Definition

```bash
curl -s https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/catalog-entities/extensions/plugins/<plugin-name>.yaml
```

Key fields:
- `metadata.name` — canonical plugin name
- `metadata.title` — display name
- `spec.packages` — list of package names composing the plugin
- `spec.categories` — plugin category

### Fetching Package Metadata

```bash
curl -s https://raw.githubusercontent.com/redhat-developer/rhdh-plugin-export-overlays/main/workspaces/<plugin-name>/metadata/<package-name>.yaml
```

Key fields:
- `spec.dynamicArtifact` — OCI image reference to use in `dynamic-plugins.yaml`
- `spec.backstage.role` — `frontend-plugin`, `backend-plugin`, or `backend-plugin-module`
- `spec.appConfigExamples` — configuration snippets for both dynamic plugin wiring and backend config
- `spec.partOf` — which plugin(s) this package belongs to
