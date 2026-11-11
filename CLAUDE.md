# CLAUDE.md

Guidance for working in this repository.

## Project overview

This repository provides **PR-driven deployment of Red Hat Developer Hub (RHDH)
test instances** on OpenShift. Users open a PR (optionally with configuration
changes) and comment `/test deploy <helm|operator> <version> [duration]
[--plugins <list>]`. Prow provisions the cluster, runs `deploy.sh`, and posts the
URL and credentials back to the PR.

Primary use case: RHDH Test Day — many instances in separate namespaces on one
cluster, sharing a single Keycloak.

The codebase is Bash and YAML only.

## Supported versions

`2.2`, `2.2.<patch>`, `2.2-<build>-CI`, and `next` (newest CI stream). The
supported release lines live in `SUPPORTED_RELEASE_LINES` in
`scripts/deployment-common.sh`; everything else is derived from the version.

## Deployment flow

```
deploy.sh
├── parses <helm|operator> <version> [--namespace] [--plugins]
├── sources .env (local) or uses CI-injected Vault secrets (OPENSHIFT_CI=true)
├── resolves plugins, builds the merged configuration:
│   ├── app-config-rhdh.yaml   base config + selected plugins' app-config.yaml
│   └── dynamic-plugins.yaml   bundled defaults + selected plugins' entries
├── creates the namespace, computes RHDH_BASE_URL and CLUSTER_ROUTER_BASE
├── scripts/setup-resources.sh: rhdh-secrets, ConfigMaps, catalog entities,
│   image imports, demo workloads
├── scripts/config-plugins.sh: plugin setup steps, round-robin
│   └── keycloak is always on: shared Keycloak + per-namespace OIDC client
└── helm/deploy.sh or operator/deploy.sh
```

## Plugins

Every optional feature is a plugin selected with `--plugins` / `PLUGINS`:
`kubernetes`, `bulk-import`, `intelligent-assistant`, `orchestrator`,
`scorecard`, `rbac`, `lighthouse`. `all` enables every plugin; `-name` excludes
one (`all,-orchestrator`). `keycloak` is always on.

A plugin may contribute:

- `resources/<name>/dynamic-plugins.yaml` — plugin entries
- `resources/<name>/app-config.yaml` — merged into `app-config-rhdh`
- `resources/<name>/*.yaml` — resources applied by its setup functions
- `scripts/plugins/config-<name>-plugin.sh` — setup/teardown functions
- an entry in `PLUGIN_SETUP_FUNCTIONS` / `PLUGIN_TEARDOWN_FUNCTIONS` in
  `scripts/config-plugins.sh` (`":"` for config-only plugins)

Orchestrator and Intelligent Assistant plugins are supplied by the Helm chart
and the Operator flavours; do not duplicate them in `dynamic-plugins.yaml`.

## Key files

- `scripts/deployment-common.sh` — version parsing, plugin resolution, merged
  configuration builders, catalog image resolution
- `scripts/config-plugins.sh` — plugin registry and round-robin executor
- `scripts/setup-resources.sh` — namespace-scoped resources and teardown
- `scripts/verify-plugins.sh` — renders the deployment and runs the real
  installer; `make verify-plugins`
- `helm/deploy.sh`, `helm/value_file.yaml` — chart values and install
- `operator/install-operator.sh`, `operator/deploy.sh`, `operator/render-cr.sh` —
  OLM installation and the `rhdh.redhat.com/v1alpha5` Backstage CR
- `.github/workflows/verify-plugins.yaml` — verification for 2.2 and next

## Conventions

- **Defaults first.** Do not override product defaults in the base config. If a
  default is broken, file a bug instead of hiding it (this is why the sidebar
  search button is not hidden).
- **`app.extensions` is restated.** Backstage replaces arrays across config
  files, so `config/app-config-rhdh.yaml` repeats the product defaults
  (`page:home`, the duplicate search widget toggle, the TechDocs add-ons) before
  adding the language list. `make verify-plugins` fails on drift.
- **`ref://` for bundled plugins.** Entries available in the catalog use
  `ref://`. Plugins missing from the catalog (MCP actions backend, Lighthouse)
  use pinned overlay images with explicit `bs_<backstage>__<version>` tags.
  `make verify-plugins` checks the pins against the release's Backstage version.
- **Per-plugin files are `plugins:` documents.** `resources/<name>/dynamic-plugins.yaml`
  has the same layout as the Operator flavours: a `plugins:` list, merged by
  `build_dynamic_plugins`.
- **Both install methods must work.** Component plugins come from the chart or
  the Operator flavour so Helm and Operator stay aligned.
- **`SEGMENT_TEST_MODE=true`** is set for both methods.
- **Secrets are generated at deploy time** (`SESSION_SECRET`, `BACKEND_SECRET`,
  `MCP_TOKEN`). Only `GITHUB_TOKEN`, `SONARQUBE_API_KEY` and LLM credentials are
  copied from the environment, and only when provided.
- Keycloak uses a **plain HTTP route**: cluster-pool ingress certificates are
  self-signed.
- Do not add release-specific workarounds (specific RC builds, catalog digests,
  `OPERATOR_EXPECTED_*` checks). `VERSION` selects the release.

## Verification

```bash
make verify-plugins VERSION=2.2 PLUGINS=all
bash scripts/verify-plugins.sh --version 2.2 --plugins all --native  # macOS
```

The script renders the chart, runs the init container's installer against the
rendered plugin list, checks pinned overlay tags against the Backstage version,
and validates the Operator CR. It needs `helm`, `yq`, `jq` and `podman`
(or Node 22+ and `skopeo` with `--native`).

## Local commands

```bash
make deploy-helm VERSION=2.2 PLUGINS=kubernetes,rbac
make deploy-operator VERSION=2.2 PLUGINS=all,-orchestrator
make install-operator VERSION=2.2      # one-time per cluster, runs in a container
make deploy-keycloak                   # one-time: shared Keycloak, realm, users
make undeploy-helm                     # keeps shared Keycloak and the Operator
make undeploy-keycloak                 # only when no instances remain
make status logs url
make smoke NAMESPACE=rhdh              # Playwright checks against a live instance
```

`/test deploy` runs `make smoke` automatically after the rollout and reports the
result in the PR; a failure does not tear down the instance. Only RHDH 2.2 and
`next` are supported (`SUPPORTED_RELEASE_LINES`); 2.1 is out of scope.

## Intelligent Assistant specifics

- OKP is not supported: the no-OKP stack (`lightspeed-stack-no-okp.yaml`) is
  always used when a provider is configured.
- Object names: `intelligent-assistant-stack` ConfigMap (key
  `lightspeed-stack.yaml`), `intelligent-assistant-secrets` Secret,
  `rhdh-intelligent-assistant-egress` NetworkPolicy,
  `INTELLIGENT_ASSISTANT_STACK_FILE` env override.
- The MCP actions backend is pinned in
  `resources/intelligent-assistant/dynamic-plugins.yaml`; plugin-side app-config
  (DCR, static token, action sources) lives in its `app-config.yaml`.
