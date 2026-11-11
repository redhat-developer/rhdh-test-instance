---
name: deploy
description: This skill should be used when the user asks to "deploy a test instance", "create a test deployment", "deploy RHDH", "spin up a test instance", "deploy with helm", "deploy with operator", "set up a test environment", "create a PR deployment", "use /test deploy", "enable a plugin", "disable a plugin", "add a plugin", "configure a plugin", "list available plugins", "show plugins", "install plugin", "remove plugin", "configure dynamic plugins", "add dynamic plugin", "verify plugin configuration", or mentions deploying an RHDH instance or enabling, disabling, or configuring dynamic plugins.
allowed-tools: Bash(gh *), Bash(git *), Bash(oc *), Bash(kubectl *), Bash(*vault*), Bash(curl *), Bash(ls *), Bash(make *), Bash(bash *), Read, Edit, Write, WebFetch
---

# Deploy & Configure RHDH Test Instance

Deploys RHDH test instances on OpenShift (`2.2` or `next`) from a PR or
locally. Optional features are plugins selected with `PLUGINS` / `--plugins`.
Read `README.md` and `CLAUDE.md` first; they are the source of truth.

## Part 1: Configuration model

`deploy.sh` builds two files before touching the cluster:

1. `app-config-rhdh.yaml` — `config/app-config-rhdh.yaml` merged with every
   selected plugin's `resources/<plugin>/app-config.yaml`. Maps merge; arrays
   are replaced.
2. `dynamic-plugins.yaml` — `config/dynamic-plugins.yaml` (includes the bundled
   defaults) plus the selected plugins' `resources/<plugin>/dynamic-plugins.yaml`,
   each a document with a `plugins:` list (same layout as the Operator
   flavours).

Plugins are enabled by name: `kubernetes`, `bulk-import`,
`intelligent-assistant`, `orchestrator`, `scorecard`, `rbac`, `lighthouse`
(`all`, `all,-orchestrator`). `keycloak` is always on. Unknown names fail the
deployment.

Orchestrator and Intelligent Assistant dynamic plugins come from the Helm chart
and the Operator flavours. Never list them again in `dynamic-plugins.yaml`.
Intelligent Assistant is off unless selected; OKP is not supported, so a
configured provider always renders the no-OKP stack.

### Adding a plugin

1. **Check the bundled catalog first.** If the plugin is in
   `dynamic-plugins.default.yaml` of the selected release, use `ref://<name>`.
   Verify with `make verify-plugins VERSION=2.2 PLUGINS=<name>`.
2. **Only if it is missing**, pin the overlay image from
   [rhdh-plugin-export-overlays](https://github.com/redhat-developer/rhdh-plugin-export-overlays):
   - catalog: `catalog-entities/extensions/plugins/<plugin>.yaml`
   - metadata: `workspaces/<plugin>/metadata/<package>.yaml`, use
     `spec.dynamicArtifact`, never construct the reference manually
   - keep `bs_<backstage>__<version>` in sync with the release (the verifier
     fails on drift)
3. Create `resources/<plugin>/dynamic-plugins.yaml` with the packages,
   `resources/<plugin>/app-config.yaml` if configuration is needed, and any
   cluster resources.
4. Add setup/teardown functions to `scripts/plugins/config-<plugin>-plugin.sh`
   and register them in `PLUGIN_SETUP_FUNCTIONS` /
   `PLUGIN_TEARDOWN_FUNCTIONS` in `scripts/config-plugins.sh` (`":"` for
   config-only plugins).
5. Run `make verify-plugins VERSION=2.2 PLUGINS=<plugin>` and commit.

### Configuration rules

- Do not override product defaults in the base configuration: no hidden
  widgets, no copied quickstart steps, no catalog overrides. Broken defaults are
  bugs, not configuration problems.
- `app.extensions` arrays are replaced across config files: when adding one,
  restate the product defaults (`page:home`, the duplicate search widget toggle,
  the TechDocs add-ons). `make verify-plugins` fails on drift.
- Do not pin versions for plugins that the catalog provides; use `ref://`.
- Configuration shared by all deployments belongs in
  `config/app-config-rhdh.yaml`; plugin-specific configuration belongs in the
  plugin folder.
- `PLUGIN_SETUP_FUNCTIONS` steps run round-robin, so long waits do not block
  other plugins.

## Part 2: Deployment

### PR deployment

```text
/test deploy <helm|operator> <version> [duration] [--plugins <list>]
```

```text
/test deploy helm 2.2 4h
/test deploy operator next 3h --plugins kubernetes,intelligent-assistant
```

Prow forwards only `--plugins`; do not expect other flags to reach `deploy.sh`.

### Local deployment

```bash
make deploy-helm VERSION=2.2 PLUGINS=kubernetes,rbac
make deploy-operator VERSION=2.2 PLUGINS=all,-orchestrator
make install-operator VERSION=2.2     # once per cluster, containerized
make deploy-keycloak                  # once per cluster: shared Keycloak + test users
make verify-plugins VERSION=2.2 PLUGINS=all
```

Add `--native` to `scripts/verify-plugins.sh` on Apple Silicon.

### Test Day

Many instances, one cluster: run `make install-operator` and
`make deploy-keycloak` once, then deploy each namespace. Keycloak install is
skipped when it is already running, so parallel deploys do not race.
`make clean NAMESPACE=<ns>` removes only that instance (namespace, OIDC client,
ClusterRoleBinding).

### Versions

`2.2`, `2.2.<patch>`, `2.2-<build>-CI`, `next`. The chart tag, catalog image and
Operator channel are derived from the version; nothing is hardcoded per build.

### After deployment

```bash
make status
make logs
make url
make smoke NAMESPACE=<ns> EXPECT_PLUGINS=kubernetes,rbac ABSENT_PLUGINS=intelligent-assistant
```

Sign in through Keycloak: `test1` / `test1@123` (admin), `test2` / `test2@123`
(developer). Keycloak is shared in `rhdh-keycloak`; each namespace has its own
OIDC client.

## Verification

`make verify-plugins` renders the Helm deployment with the real values and runs
the same `install-dynamic-plugins` installer as the init container. It fails on
unresolvable `ref://` entries, conflicting configuration, pull failures,
`bs_` tag drift and `app.extensions` defaults that are not restated, and
validates the Operator CR. GitHub Actions runs it for `2.2` and `next` on
configuration PRs, weekly, and on demand.

`make smoke` verifies a live instance with Playwright: Keycloak sign-in,
`loaded-plugins`, home page defaults, the global search box, the language selector
and the selected plugins' routes. Every `/test deploy` runs it automatically and
reports the result in the PR; a failure keeps the instance up for debugging.

Always run it before proposing a configuration change. Do not report a
deployment as verified without it.

## Troubleshooting

```bash
oc get pods -n <namespace>
oc logs deployment/<redhat-developer-hub|backstage-developer-hub> \
  -c install-dynamic-plugins -n <namespace>
oc get events -n <namespace> --sort-by=.lastTimestamp | tail
oc get pods -n rhdh-keycloak
oc get route keycloak -n rhdh-keycloak
```

If the rollout fails, `deploy.sh` prints the installer logs automatically.

## Secrets

Never print secret values. CI reads them from Vault
(`selfservice/rhdh-test-instance/`); local deployments read `.env`.
`SESSION_SECRET`, `BACKEND_SECRET` and `MCP_TOKEN` are generated at deploy time.
`GITHUB_TOKEN`, `SONARQUBE_API_KEY` and LLM credentials are optional and only
used when provided.
