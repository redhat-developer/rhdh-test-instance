# Configuration Files Reference

Detailed guide to each configuration file in the `config/` and `helm/` directories.

## config/app-config-rhdh.yaml

Main RHDH (Backstage) application configuration. Applied as a ConfigMap on the cluster.

### Structure

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
    - type: url
      target: https://github.com/redhat-developer/red-hat-developer-hub-software-templates/blob/main/templates.yaml

  providers:
    keycloakOrg:                        # Syncs users/groups from Keycloak (auto-configured)
      default:
        baseUrl: "${KEYCLOAK_BASE_URL}"
        realm: "${KEYCLOAK_REALM}"
```

### Common Modifications

**Add a catalog location** (most common):
```yaml
catalog:
  locations:
    # ... existing entries ...
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

### Environment Variable References

All `${VAR}` placeholders are substituted at runtime. Variables come from:
- Keycloak deploy script (auto-set): `KEYCLOAK_*`, `RHDH_BASE_URL`
- Vault secrets (PR deployments): any key stored in Vault
- `.env` file (local deployments): user-defined

To add a new variable: define it in `config/rhdh-secrets.yaml`, then reference it in app-config as `${VAR_NAME}`.

---

## config/dynamic-plugins.yaml

Controls which dynamic plugins are enabled in the RHDH instance.

### Structure

```yaml
includes:
  - dynamic-plugins.default.yaml       # Inherit default plugin set from catalog index

plugins:
  - package: ./dynamic-plugins/dist/backstage-community-plugin-catalog-backend-module-keycloak-dynamic
    disabled: false
```

### Adding a Plugin

Append to the `plugins` list:

```yaml
plugins:
  # ... existing entries ...
  - package: ./dynamic-plugins/dist/plugin-package-name
    disabled: false
```

For OCI-based plugins (from registry):
```yaml
  - package: 'oci://registry.access.redhat.com/rhdh/plugin-name:{{inherit}}'
    disabled: false
```

The `{{inherit}}` tag resolves the plugin version from the catalog index image at runtime.

### Plugin Configuration

Some plugins require additional config in `app-config-rhdh.yaml`. Check the plugin's documentation for required configuration keys.

---

## config/orchestrator-dynamic-plugins.yaml

Orchestrator-specific plugins. These are **automatically merged** into `dynamic-plugins.yaml` when the deployment uses `ORCH=true` or `--with-orchestrator`. Do not manually merge.

### Contents

```yaml
plugins:
  - package: 'oci://registry.access.redhat.com/rhdh/...-plugin-orchestrator:{{inherit}}'
  - package: 'oci://registry.access.redhat.com/rhdh/...-plugin-orchestrator-backend:{{inherit}}'
  - package: 'oci://registry.access.redhat.com/rhdh/...-scaffolder-backend-module-orchestrator:{{inherit}}'
  - package: 'oci://registry.access.redhat.com/rhdh/...-plugin-orchestrator-form-widgets:{{inherit}}'
```

---

## config/rhdh-secrets.yaml

Kubernetes Secret template. Environment variables are substituted at deploy time and made available to the RHDH pods.

### Adding a New Secret

1. Add the variable to `rhdh-secrets.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rhdh-secrets
stringData:
  RHDH_BASE_URL: "${RHDH_BASE_URL}"
  # ... existing entries ...
  MY_NEW_SECRET: "${MY_NEW_SECRET}"
```

2. For PR deployments, store the value in Vault under `selfservice/rhdh-test-instance/` with key `MY_NEW_SECRET`
3. For local deployments, add `export MY_NEW_SECRET="value"` to `.env`
4. Reference in `app-config-rhdh.yaml` as `${MY_NEW_SECRET}`

---

## helm/value_file.yaml

Helm chart value overrides for the RHDH chart. Minimal by default — most configuration goes through `app-config-rhdh.yaml` via the ConfigMap.

### Structure

```yaml
upstream:
  backstage:
    extraAppConfig:
      - configMapRef: app-config-rhdh
        filename: app-config-rhdh.yaml
    extraEnvVarsSecrets:
      - rhdh-secrets
```

### Adding Helm Overrides

To customize Helm-specific values (resource limits, replicas, etc.), add under the `upstream` key following the RHDH Helm chart schema.

Example — set resource limits:
```yaml
upstream:
  backstage:
    extraAppConfig:
      - configMapRef: app-config-rhdh
        filename: app-config-rhdh.yaml
    extraEnvVarsSecrets:
      - rhdh-secrets
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 4Gi
```

---

## operator/subscription.yaml

Backstage Custom Resource (CR) for operator-based deployments. Defines how the operator should configure the RHDH instance.

### Key Fields

- `spec.application.appConfig.configMapRef` — references the app-config ConfigMap
- `spec.application.dynamicPluginsConfigMapName` — references the dynamic plugins ConfigMap
- `spec.database.enableLocalDb` — uses a local PostgreSQL database
- `spec.application.route.enabled` — creates an OpenShift Route
