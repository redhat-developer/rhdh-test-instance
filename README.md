# RHDH Test Instance

Deploys Red Hat Developer Hub (RHDH) test instances on OpenShift, from pull
requests or locally. The primary use case is RHDH Test Day: many independent
instances on a single cluster, each in its own namespace, sharing one Keycloak.

## Features

- **Helm and Operator** installation methods
- **RHDH 2.2 and `next`** — `2.2`, a patch release (`2.2.3`), a CI build
  (`2.2-120-CI`), or `next` for the newest CI stream
- **Shared Keycloak** — one Keycloak per cluster, one OIDC client per namespace,
  test users `test1` (admin) and `test2` (developer)
- **Optional plugins** — `kubernetes`, `bulk-import`,
  `intelligent-assistant`, `orchestrator`, `scorecard`, `rbac`, `lighthouse`
- **Configuration verification** — renders the deployment and runs the real
  plugin installer before anything is applied (`make verify-plugins`)

## GitHub PR workflow

Comment on a pull request to deploy:

```text
/test deploy <helm|operator> <version> [duration] [--plugins <list>]
```

Examples:

```text
/test deploy helm 2.2 4h
/test deploy operator next 3h
/test deploy helm 2.2 4h --plugins kubernetes,rbac
```

The bot replies with the RHDH URL, the OpenShift console link, and cluster
credentials. Deployments run for the requested duration (default 3h, maximum 4h).

Prow job status:
<https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy>

To test configuration changes, open a PR with the modified `config/` or
`resources/` files and deploy from that PR.

> The Prow step currently forwards only `--plugins`. Passing `--with` or other
> flags through the PR comment requires a change in `openshift/release`.

## Local deployment

Requirements: `oc` (logged in), `helm`, `jq`, Mike Farah's `yq` v4, `make`,
`skopeo`, `python3`, and `podman` for containerized operator installation.

```bash
cp .env.example .env        # optional; needed for tokens or LLM providers
make deploy-helm VERSION=2.2
make deploy-operator VERSION=2.2
```

`make install-operator VERSION=2.2` installs the Operator through OLM. It runs
in the e2e-runner container because it needs `umoci`, `opm` and `skopeo`. It is
only required once per cluster.

### Common commands

```bash
make deploy-helm VERSION=2.2 PLUGINS=kubernetes,rbac
make deploy-helm VERSION=2.2 PLUGINS=all,-orchestrator
make deploy-helm VERSION=next NAMESPACE=team-a

make status
make logs
make url

make undeploy-helm                       # keep shared Keycloak and the Operator
make undeploy-keycloak                   # only when no instances remain
make uninstall-operator
make clean                               # delete the namespace
```

### Variables

| Variable            | Default                                       | Description                                                    |
| ------------------- | --------------------------------------------- | -------------------------------------------------------------- |
| `NAMESPACE`         | `rhdh`                                        | Target namespace                                               |
| `VERSION`           | `2.2`                                         | `2.2`, `2.2.x`, `2.2-<build>-CI`, or `next`                    |
| `PLUGINS`           | _(empty)_                                     | Comma-separated plugins, `all`, or `all,-name`                 |
| `USE_CONTAINER`     | `false`                                       | Run the deployment inside the e2e-runner container             |
| `CATALOG_INDEX_IMAGE` | bundled with the chart/Operator             | Full plugin catalog image (registry/repository:tag or digest)  |
| `CATALOG_INDEX_TAG` | _(empty)_                                     | Shortcut for `quay.io/rhdh/plugin-catalog-index:<tag>`         |
| `RHDH_IMAGE`        | chart/Operator default                        | RHDH container image override                                  |
| `KEYCLOAK_NS`       | `rhdh-keycloak`                               | Namespace of the shared Keycloak                               |
| `OPERATOR_NAMESPACE`| `rhdh-operator-system`                        | Namespace of the RHDH Operator                                 |
| `RUNNER_IMAGE`      | `quay.io/rhdh-community/rhdh-e2e-runner:main` | Container image for `install-operator`                         |

## Plugins

Every optional feature is selected with `PLUGINS` / `--plugins`. `all` enables
everything; `-name` excludes a plugin (`all,-orchestrator`).

| Plugin | What it adds |
| --- | --- |
| `kubernetes` | Kubernetes and Topology plugins, the service account read access they need, and a `topology-test` entity |
| `bulk-import` | Bulk import of existing repositories (needs `GITHUB_TOKEN`) |
| `intelligent-assistant` | Intelligent Assistant with the MCP actions backend, optional LLM provider, and MCP client access |
| `orchestrator` | Orchestrator plugins plus the Serverless/Logic infrastructure |
| `scorecard` | Scorecard metrics (GitHub, OpenSSF, Dependabot, SonarQube, filecheck) |
| `rbac` | RBAC frontend, permission framework, and test policies |
| `lighthouse` | Lighthouse audit service and plugin |

`keycloak` is always installed — OIDC through the shared Keycloak is the
sign-in method for every instance. The plugin name is still accepted for
compatibility.

Each plugin contributes `resources/<name>/dynamic-plugins.yaml`, optionally
`resources/<name>/app-config.yaml`, optional cluster resources, and setup steps
in `scripts/config-plugins.sh`.

Base deployments follow the product defaults: no hidden widgets, no copied
quickstart steps, no catalog overrides. When a default is wrong, file a bug
rather than override it.

## Verification

```bash
make verify-plugins VERSION=2.2 PLUGINS=all
```

The script renders the Helm deployment with the real chart values, extracts the
plugin list and images from the rendered manifests, and runs the same
`install-dynamic-plugins` installer the init container runs. It fails on:

- `ref://` entries the selected catalog cannot resolve
- conflicting or duplicate plugin configuration
- plugin images that cannot be pulled
- pinned overlay images (`bs_<backstage>__…`) that do not match the release

It also renders the Backstage CR and checks the flavour selection.

On Apple Silicon, the RHDH image has to be emulated, which is slow. Add
`--native` to run the installer with the host's Node.js and `skopeo` instead:

```bash
bash scripts/verify-plugins.sh --version 2.2 --plugins all --native
```

The container run remains the authoritative check; GitHub Actions runs it for
`2.2` and `next` on every PR that touches configuration, weekly, and on demand
(`.github/workflows/verify-plugins.yaml`).

## Sign-in and credentials

Every instance uses OIDC through the shared Keycloak:

| User | Password | Groups | Role |
| --- | --- | --- | --- |
| `test1` | `test1@123` | developers, admins, viewers | RBAC admin |
| `test2` | `test2@123` | developers | RBAC developer |

`GITHUB_TOKEN` is optional and only used when supplied. Without it, catalog
locations and Scorecard use public GitHub access and bulk import cannot open
pull requests.

## Repository layout

```text
.
├── config/
│   ├── app-config-rhdh.yaml            # Base app-config
│   └── dynamic-plugins.yaml            # includes: bundled defaults, plugins: []
├── helm/
│   ├── deploy.sh                       # Chart values, orchestrator infra, install
│   └── value_file.yaml                 # Chart values
├── operator/
│   ├── install-operator.sh             # OLM installation from the published IIB
│   ├── deploy.sh                       # Applies the Backstage CR
│   ├── backstage.yaml                  # Backstage CR template (v1alpha5)
│   └── render-cr.sh                    # Renders the CR without cluster access
├── resources/
│   ├── catalog-entities/               # Catalog entity ConfigMaps (always applied)
│   ├── image-stream-imports/           # Image pre-imports
│   ├── rhdh-script-examples/           # Demo workloads for Topology/Kubernetes
│   ├── keycloak/                       # Shared Keycloak: users, groups, values
│   └── <plugin>/                       # Per-plugin config and resources
├── scripts/
│   ├── deployment-common.sh            # Versions, plugins, merged configuration
│   ├── config-plugins.sh               # Plugin setup/teardown executor
│   ├── setup-resources.sh              # Namespace-scoped resources
│   ├── verify-plugins.sh               # Pre-deployment verification
│   └── plugins/config-<name>-plugin.sh # Plugin setup/teardown steps
├── deploy.sh
├── teardown.sh
└── Makefile
```

## How configuration is assembled

`deploy.sh` builds two files before touching the cluster:

1. `app-config-rhdh.yaml` — the base config merged with every selected plugin's
   `app-config.yaml`. Maps merge recursively; arrays are replaced, exactly like
   Backstage's own config layering.
2. `dynamic-plugins.yaml` — `dynamic-plugins.default.yaml` plus the selected
   plugins' entries.

Both are applied as ConfigMaps. Helm receives the plugin list as chart values;
the Operator reads the ConfigMap. Component plugins shipped by the chart or the
Operator flavours (Orchestrator, Intelligent Assistant) are not duplicated in
the plugin list.

## Secrets

PR deployments get secrets from Vault
(`selfservice/rhdh-test-instance/`); the deployment writes them into
`rhdh-secrets` in the instance namespace. Local deployments read `.env`.

- `SESSION_SECRET`, `BACKEND_SECRET`, `MCP_TOKEN` are generated when missing.
- `KEYCLOAK_*` are written by the Keycloak setup.
- `GITHUB_TOKEN`, `SONARQUBE_API_KEY` and LLM provider credentials are only set
  when provided.

## Troubleshooting

```bash
oc get pods -n <namespace>
oc logs deployment/<redhat-developer-hub|backstage-developer-hub> -c install-dynamic-plugins -n <namespace>
oc get events -n <namespace> --sort-by=.lastTimestamp | tail
```

If the rollout fails, `deploy.sh` prints the dynamic plugin installer logs.

Keycloak problems:

```bash
oc get pods -n rhdh-keycloak
oc get route keycloak -n rhdh-keycloak
oc get secret keycloak-test-credentials -n rhdh-keycloak -o jsonpath='{.data}' | jq .
```
