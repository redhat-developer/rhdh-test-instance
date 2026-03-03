---
name: deploy
description: This skill should be used when the user asks to "deploy a test instance", "create a test deployment", "deploy RHDH", "spin up a test instance", "deploy with helm", "deploy with operator", "set up a test environment", "create a PR deployment", "use /test deploy", or mentions deploying an RHDH instance via a PR or using the /test deploy slash command.
allowed-tools: Bash(gh *), Bash(git *), Bash(oc *), Bash(kubectl *), Bash(*vault*)
---

# Deploy RHDH Test Instance

This skill guides users through deploying an RHDH test instance via the GitHub PR workflow. The primary deployment method is opening a PR on the `rhdh-test-instance` repo and using the `/test deploy` slash command in PR comments. Prow CI handles provisioning, Keycloak auth setup, and RHDH installation automatically.

## Deployment Workflow

### Step 1: Determine Configuration Needs

Ask the user:

1. **Install type** — `helm` or `operator`
2. **RHDH version** — semantic (e.g. `1.9`), CI build (e.g. `1.9-190-CI`), or `next`
3. **Duration** — how long the instance should stay up (default: `3h`, e.g. `4h`, `2.5h`)
4. **Custom configuration** — whether they need non-default app-config, plugins, or secrets

If the user does not need custom configuration, skip to Step 3.

### Step 2: Prepare Custom Configuration (if needed)

If the user needs custom configuration, create a new branch and make changes to the relevant files. Consult `references/config-files.md` for details on each configuration file, what it controls, and common modification patterns.

The key configuration files are:

| File | Purpose |
|---|---|
| `config/app-config-rhdh.yaml` | RHDH app config (auth, catalog, providers) |
| `config/dynamic-plugins.yaml` | Plugin enablement |
| `config/rhdh-secrets.yaml` | Kubernetes Secret with env vars |
| `helm/value_file.yaml` | Helm chart value overrides |
| `operator/subscription.yaml` | Backstage CR for operator deployments |

Common customizations:

- **Adding catalog locations** — add entries under `catalog.locations` in `app-config-rhdh.yaml`
- **Enabling plugins** — add plugin entries to `config/dynamic-plugins.yaml`
- **Adding secrets/env vars** — add to `config/rhdh-secrets.yaml` and reference in app-config via `${VAR_NAME}`; for PR deployments, the actual secret values must be stored in Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`

After making changes, commit and push the branch, then open a PR.

### Step 3: Create the PR

If no custom config is needed, create a minimal PR (e.g. an empty commit or a small README change) to get a PR number for the `/test` command.

Use `gh` CLI to create the PR:

```bash
git checkout -b <branch-name>
git commit --allow-empty -m "Deploy test instance"
git push -u origin <branch-name>
gh pr create --title "Deploy RHDH <version> test instance" --body "Deploying RHDH test instance for testing."
```

### Step 4: Trigger Deployment

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

### Step 5: Monitor and Share Results

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

## Additional Resources

### Reference Files

- **`references/config-files.md`** — detailed guide to each configuration file, its structure, and common modification patterns
