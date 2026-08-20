# OSL RC smoke subset Implementation Plan

> **Implementation note (2026-08-20):** Do not add Python helpers. The approved architecture is the earlier **Lean OSL smoke bash** plan: `run-osl-regression.sh` only, GraphQL classification with `jq`, Playwright `--grep` as a bash constant. The task bodies below that mention `osl_smoke.py` / `test_osl_smoke.py` are obsolete.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Default OSL RC `--test` probes raw Data Index GraphQL, then runs four Playwright tests (Greeting + Failswitch statuses + retrigger + token-propagation).

**Architecture:** Keep the existing bash driver. It always deploys greeting, failswitch, and token-propagation, probes raw Data Index with `oc exec` + `jq`, then Playwright `-g` for the four titles. Do not change overlays git files; keep copying `playwright/osl-regression-smoke.spec.ts` at runtime.

**Tech Stack:** bash, jq, oc, Playwright (overlays e2e-tests), existing smoke wrapper.

**Spec:** `docs/superpowers/specs/2026-08-20-osl-rc-smoke-subset.md`

## Global Constraints

- Repo: `rhdh-test-instance` only, branch `feat/rhidp-13375-osl-smoke`, worktree `/home/rlan/redhat/rhdh-test-instance/.worktrees/rhidp-13375-osl-smoke`.
- Do not edit `rhdh-plugin-export-overlays`, `rhdh-plugins`, or `rhdh-e2e-test-utils`.
- Do not commit `.env`, `.env.osl`, or cluster credentials.
- Driver is bash. Classify GraphQL with `jq`. Do not add Python helper modules.
- Default Playwright titles (exact): `Run Greeting workflow and verify Workflows tab`, `Run Failswitch workflow and verify statuses`, `Rerun Failswitch from failure point`, `Execute token-propagation workflow via API`.
- Probe the raw Data Index service, never `osl-di-rewrite`.
- Driver `--cleanup` always includes operators/catalog/mirror. No `--full-e2e` flag.
- Commit messages: conventional commits, include `#13375`.
- `export PATH="/home/rlan/bin:$HOME/.local/bin:$PATH"` before any `oc` command.

---

## File map

| File | Responsibility |
|---|---|
| `run-osl-regression.sh` | `--allow-relative-service-url`, always deploy token-propagation on smoke, probe raw Data Index with `jq`, pass `--grep` |
| `playwright/osl-regression-smoke.spec.ts` | Always register token-propagation tests |
| `README.md` | Default 4-test smoke, probe, `--allow-relative-service-url` |
| `Makefile` | Pass-through `ALLOW_RELATIVE_SERVICE_URL=1` |

Do **not** implement Orchestrator plugin `serviceUrl` derivation here. That is `docs/superpowers/plans/2026-08-20-orchestrator-serviceurl-from-endpoint.md`.

---

### Task 1: Python smoke helper + unit tests

**Files:**
- Create: `utils/orchestrator/osl_smoke.py`
- Create: `utils/orchestrator/test_osl_smoke.py`

**Interfaces:**
- Consumes: none
- Produces:
  - `SMOKE_TITLES: list[str]` (four titles, including token-propagation)
  - `playwright_grep() -> str`
  - `is_absolute_http_url(value: str | None) -> bool`
  - `classify_definitions(definitions: list) -> dict` with keys `ok` (bool), `problems` (list of `{id, serviceUrl, endpoint, reason}`)
  - CLI: `python utils/orchestrator/osl_smoke.py grep` prints the regex to stdout
  - CLI: `python utils/orchestrator/osl_smoke.py classify` reads GraphQL JSON on stdin, exit 0/2

- [ ] **Step 1: Write the failing tests**

Create `utils/orchestrator/test_osl_smoke.py`:

```python
#!/usr/bin/env python3
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import osl_smoke  # noqa: E402


class TestPlaywrightGrep(unittest.TestCase):
    def test_default_titles(self):
        self.assertEqual(
            osl_smoke.SMOKE_TITLES,
            [
                "Run Greeting workflow and verify Workflows tab",
                "Run Failswitch workflow and verify statuses",
                "Rerun Failswitch from failure point",
                "Execute token-propagation workflow via API",
            ],
        )

    def test_grep_joins_four_escaped_titles(self):
        pattern = osl_smoke.playwright_grep()
        self.assertIn("Run Greeting workflow and verify Workflows tab", pattern)
        self.assertIn("Run Failswitch workflow and verify statuses", pattern)
        self.assertIn("Rerun Failswitch from failure point", pattern)
        self.assertIn("Execute token-propagation workflow via API", pattern)
        self.assertNotIn("Verify Workflow All Runs", pattern)


class TestServiceUrl(unittest.TestCase):
    def test_absolute_http(self):
        self.assertTrue(
            osl_smoke.is_absolute_http_url(
                "http://greeting.orchestrator.svc.cluster.local"
            )
        )

    def test_absolute_https(self):
        self.assertTrue(osl_smoke.is_absolute_http_url("https://example.example"))

    def test_relative_path(self):
        self.assertFalse(osl_smoke.is_absolute_http_url("/greeting"))

    def test_empty_and_none(self):
        self.assertFalse(osl_smoke.is_absolute_http_url(""))
        self.assertFalse(osl_smoke.is_absolute_http_url(None))


class TestClassifyDefinitions(unittest.TestCase):
    def test_all_absolute_ok(self):
        result = osl_smoke.classify_definitions(
            [
                {
                    "id": "greeting",
                    "serviceUrl": "http://greeting.orchestrator.svc",
                    "endpoint": "http://greeting.orchestrator.svc/greeting",
                }
            ]
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["problems"], [])

    def test_relative_service_url_is_problem(self):
        result = osl_smoke.classify_definitions(
            [
                {
                    "id": "greeting",
                    "serviceUrl": "/greeting",
                    "endpoint": "http://greeting.orchestrator.svc/greeting",
                }
            ]
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["problems"][0]["id"], "greeting")
        self.assertEqual(result["problems"][0]["reason"], "relative-or-missing-serviceUrl")

    def test_empty_list_not_ok(self):
        result = osl_smoke.classify_definitions([])
        self.assertFalse(result["ok"])
        self.assertEqual(result["problems"][0]["reason"], "no-process-definitions")


class TestClassifyCli(unittest.TestCase):
    def test_classify_stdin_exit_2_on_relative(self):
        payload = json.dumps(
            {
                "data": {
                    "ProcessDefinitions": [
                        {"id": "greeting", "serviceUrl": "/greeting", "endpoint": "http://x/greeting"}
                    ]
                }
            }
        )
        proc = subprocess.run(
            [sys.executable, str(HERE / "osl_smoke.py"), "classify"],
            input=payload,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export PATH="/home/rlan/bin:$HOME/.local/bin:$PATH"
cd /home/rlan/redhat/rhdh-test-instance/.worktrees/rhidp-13375-osl-smoke
python3 utils/orchestrator/test_osl_smoke.py
```

Expected: FAIL with `ModuleNotFoundError: No module named 'osl_smoke'` or import error.

- [ ] **Step 3: Write minimal implementation**

Create `utils/orchestrator/osl_smoke.py`:

```python
#!/usr/bin/env python3
"""OSL RC smoke helpers: Playwright grep and Data Index serviceUrl contract."""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any, Optional

SMOKE_TITLES = [
    "Run Greeting workflow and verify Workflows tab",
    "Run Failswitch workflow and verify statuses",
    "Rerun Failswitch from failure point",
    "Execute token-propagation workflow via API",
]


def playwright_grep() -> str:
    return "|".join(re.escape(t) for t in SMOKE_TITLES)


def is_absolute_http_url(value: Optional[str]) -> bool:
    if not value:
        return False
    return value.startswith("http://") or value.startswith("https://")


def classify_definitions(definitions: list) -> dict[str, Any]:
    if not definitions:
        return {
            "ok": False,
            "problems": [
                {
                    "id": None,
                    "serviceUrl": None,
                    "endpoint": None,
                    "reason": "no-process-definitions",
                }
            ],
        }
    problems = []
    for item in definitions:
        service_url = item.get("serviceUrl")
        if not is_absolute_http_url(service_url):
            problems.append(
                {
                    "id": item.get("id"),
                    "serviceUrl": service_url,
                    "endpoint": item.get("endpoint"),
                    "reason": "relative-or-missing-serviceUrl",
                }
            )
    return {"ok": not problems, "problems": problems}


def _cmd_grep() -> int:
    print(playwright_grep())
    return 0


def _cmd_classify() -> int:
    payload = json.load(sys.stdin)
    definitions = (payload.get("data") or {}).get("ProcessDefinitions") or []
    result = classify_definitions(definitions)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    if result["ok"]:
        return 0
    if result["problems"] and result["problems"][0]["reason"] == "no-process-definitions":
        return 1
    return 2


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="osl_smoke.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("grep")
    sub.add_parser("classify")
    args = parser.parse_args(argv)
    if args.cmd == "grep":
        return _cmd_grep()
    return _cmd_classify()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/rlan/redhat/rhdh-test-instance/.worktrees/rhidp-13375-osl-smoke
python3 utils/orchestrator/test_osl_smoke.py
```

Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add utils/orchestrator/osl_smoke.py utils/orchestrator/test_osl_smoke.py \
  docs/superpowers/specs/2026-08-20-osl-rc-smoke-subset.md \
  docs/superpowers/plans/2026-08-20-osl-rc-smoke-subset.md
git commit -m "$(cat <<'EOF'
test: add OSL smoke grep and serviceUrl classifiers #13375

EOF
)"
```

---

### Task 2: Probe raw Data Index from the cluster

**Files:**
- Modify: `utils/orchestrator/osl_smoke.py` (add `probe` subcommand)
- Modify: `utils/orchestrator/test_osl_smoke.py` (build curl argv; no live cluster)
- Modify: `run-osl-regression.sh` (`phase_test` after `ensure_smoke_workflows`)

**Interfaces:**
- Consumes: `classify_definitions` from Task 1
- Produces:
  - `graphql_query() -> str` returning `{ ProcessDefinitions { id serviceUrl endpoint } }`
  - `curl_probe_argv(namespace: str) -> list[str]` for `oc exec`
  - CLI `probe --namespace <ns>` runs oc, pipes JSON to classify, honors `ALLOW_RELATIVE_SERVICE_URL=1`

- [ ] **Step 1: Write the failing tests**

Append to `utils/orchestrator/test_osl_smoke.py`:

```python
class TestProbeArgv(unittest.TestCase):
    def test_curl_targets_raw_data_index_not_rewrite(self):
        argv = osl_smoke.curl_probe_argv("orchestrator")
        joined = " ".join(argv)
        self.assertIn("sonataflow-platform-data-index-service.orchestrator.svc.cluster.local/graphql", joined)
        self.assertNotIn("osl-di-rewrite", joined)
        self.assertIn("ProcessDefinitions", joined)

    def test_graphql_query_asks_for_service_url_and_endpoint(self):
        q = osl_smoke.graphql_query()
        self.assertIn("serviceUrl", q)
        self.assertIn("endpoint", q)
        self.assertIn("ProcessDefinitions", q)
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
python3 utils/orchestrator/test_osl_smoke.py TestProbeArgv -v
```

Expected: FAIL with `AttributeError: module 'osl_smoke' has no attribute 'curl_probe_argv'`.

- [ ] **Step 3: Implement probe helpers and CLI**

Add to `osl_smoke.py` (keep existing functions). `curl_probe_argv` must be a list `oc` can consume:

```python
GRAPHQL_QUERY = "{ ProcessDefinitions { id serviceUrl endpoint } }"


def graphql_query() -> str:
    return GRAPHQL_QUERY


def curl_probe_argv(namespace: str) -> list[str]:
    body = json.dumps({"query": graphql_query()})
    url = (
        f"http://sonataflow-platform-data-index-service.{namespace}"
        ".svc.cluster.local/graphql"
    )
    return [
        "oc",
        "exec",
        "-n",
        namespace,
        "deploy/redhat-developer-hub",
        "--",
        "curl",
        "-sS",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        body,
        url,
    ]
```

Add `probe` subparser:

```python
def _cmd_probe(namespace: str, allow_relative: bool) -> int:
    import subprocess

    argv = curl_probe_argv(namespace)
    proc = subprocess.run(argv, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr or proc.stdout or "oc exec curl failed\n")
        return 1
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.stderr.write(f"Data Index did not return JSON: {proc.stdout[:500]}\n")
        return 1
    if payload.get("errors"):
        sys.stderr.write(json.dumps(payload["errors"]) + "\n")
        return 1
    definitions = (payload.get("data") or {}).get("ProcessDefinitions") or []
    result = classify_definitions(definitions)
    json.dump(result, sys.stderr, indent=2)
    sys.stderr.write("\n")
    if result["ok"]:
        return 0
    if allow_relative:
        sys.stderr.write(
            "WARNING: relative/missing serviceUrl allowed by ALLOW_RELATIVE_SERVICE_URL\n"
        )
        return 0
    if result["problems"] and result["problems"][0]["reason"] == "no-process-definitions":
        return 1
    return 2
```

Wire argparse: `probe --namespace` required; `--allow-relative` flag **or** env `ALLOW_RELATIVE_SERVICE_URL=1`.

- [ ] **Step 4: Run unit tests**

```bash
python3 utils/orchestrator/test_osl_smoke.py
```

Expected: PASS.

- [ ] **Step 5: Call probe from `phase_test`**

In `run-osl-regression.sh`, add a `run_all=false` style flag:

```bash
allow_relative_service_url=false
```

Parse:

```bash
--allow-relative-service-url) allow_relative_service_url=true; shift ;;
```

After `ensure_smoke_workflows` (smoke path only, not `--full-e2e`), before Playwright:

```bash
probe_args=(python3 "${SCRIPT_DIR}/utils/orchestrator/osl_smoke.py" probe --namespace "$namespace")
if [[ "$allow_relative_service_url" == "true" || "${ALLOW_RELATIVE_SERVICE_URL:-}" == "1" ]]; then
    probe_args+=(--allow-relative)
fi
log "probing raw Data Index GraphQL ProcessDefinitions.serviceUrl"
"${probe_args[@]}"
```

Also document in `usage()`.

- [ ] **Step 6: Commit**

```bash
git add utils/orchestrator/osl_smoke.py utils/orchestrator/test_osl_smoke.py run-osl-regression.sh
git commit -m "$(cat <<'EOF'
feat: probe raw Data Index serviceUrl before OSL Playwright #13375

EOF
)"
```

---

### Task 3: Default Playwright grep to the four OSL tests

**Files:**
- Modify: `run-osl-regression.sh` (`phase_test` Playwright invocation)
- Modify: `README.md` OSL RC smoke section

**Interfaces:**
- Consumes: `osl_smoke.py grep` from Task 1
- Produces: default `--test` runs four titles; `--full-e2e` unchanged

- [ ] **Step 1: Write a failing driver assertion (script check)**

Add to `utils/orchestrator/test_osl_smoke.py`:

```python
class TestDriverGrepWiring(unittest.TestCase):
    def test_run_script_mentions_osl_smoke_grep(self):
        text = Path(__file__).resolve().parents[2].joinpath("run-osl-regression.sh").read_text()
        self.assertIn("osl_smoke.py", text)
        self.assertIn("grep", text)
        self.assertIn("--grep", text)
```

Playwright CLI flag is `-g` / `--grep`. The driver must pass `--grep "$(python3 ... grep)"`.

- [ ] **Step 2: Run the wiring test to see it fail**

```bash
python3 utils/orchestrator/test_osl_smoke.py TestDriverGrepWiring -v
```

Expected: FAIL (`--grep` not in `run-osl-regression.sh`).

- [ ] **Step 3: Change the smoke Playwright invocation**

In `phase_test`, replace the smoke branch:

```bash
    else
        smoke_grep="$(python3 "${SCRIPT_DIR}/utils/orchestrator/osl_smoke.py" grep)"
        log "Playwright grep: ${smoke_grep}"
        # shellcheck disable=SC2086
        (cd "$e2e" && $pw test --project=orchestrator --workers=1 --grep "$smoke_grep" "$smoke_spec")
    fi
```

Leave the `--full-e2e` branch **without** `--grep`.

- [ ] **Step 4: Run unit tests**

```bash
python3 utils/orchestrator/test_osl_smoke.py
```

Expected: PASS, including `TestDriverGrepWiring`.

- [ ] **Step 5: Update README**

Replace the OSL RC smoke paragraph in `README.md` so it states:

- Default smoke is four tests (list the titles, including token-propagation).
- Token-propagation workflow + sample-server are always deployed on the smoke path.
- A GraphQL probe runs first against raw Data Index.
- `--allow-relative-service-url` continues after SRVLOGIC-1137-class relative `serviceUrl` (needed on 1.39.CR1 until the plugin fix ships).
- `--full-e2e` is the RHDH plugin suite (RBAC, entity, ui:props, Loki, all workflows), not the OSL CR default.

Example block:

```bash
./run-osl-regression.sh --all --rhdh next --osl-release 1.39.0.CR1 --namespace orchestrator
# 1.39.CR1 currently needs the DI contract override plus rewrite proxy:
ALLOW_RELATIVE_SERVICE_URL=1 ./run-osl-regression.sh --test --namespace orchestrator
./run-osl-regression.sh --test --full-e2e --namespace orchestrator
```

- [ ] **Step 6: Commit**

```bash
git add run-osl-regression.sh README.md utils/orchestrator/test_osl_smoke.py
git commit -m "$(cat <<'EOF'
feat: limit OSL RC Playwright to greeting, failswitch, retrigger, token-propagation #13375

EOF
)"
```

---

### Task 4: Always deploy and register token-propagation on smoke

**Files:**
- Modify: `run-osl-regression.sh` (`ensure_token_propagation_workflow`, call it from `ensure_smoke_workflows`, wait for the deployment)
- Modify: `playwright/osl-regression-smoke.spec.ts`
- Modify: `README.md` (if Task 3 copy still called token-propagation optional)
- Modify: `utils/orchestrator/test_osl_smoke.py` (driver and wrapper wiring)

**Interfaces:**
- Consumes: overlays token test module (read-only at runtime); Keycloak env already exported in `phase_test`
- Produces: every smoke `--test` deploys sample-server + token-propagation, registers `Execute token-propagation workflow via API`, waits Ready before the GraphQL probe

- [ ] **Step 1: Write failing wiring tests**

Append:

```python
class TestTokenSmokeWiring(unittest.TestCase):
    def test_driver_always_deploys_token_propagation(self):
        text = Path(__file__).resolve().parents[2].joinpath("run-osl-regression.sh").read_text()
        self.assertIn("ensure_token_propagation_workflow", text)
        self.assertIn("token-propagation", text)
        self.assertNotIn("--include-token-propagation", text)
        self.assertNotIn("OSL_SMOKE_TOKEN_PROPAGATION", text)

    def test_smoke_wrapper_always_registers_token_tests(self):
        text = (
            Path(__file__).resolve().parents[2]
            / "playwright"
            / "osl-regression-smoke.spec.ts"
        ).read_text()
        self.assertIn("registerTokenPropagationWorkflowTests", text)
        self.assertNotIn("OSL_SMOKE_TOKEN_PROPAGATION", text)
```

- [ ] **Step 2: Run to verify fail**

```bash
python3 utils/orchestrator/test_osl_smoke.py TestTokenSmokeWiring -v
```

Expected: FAIL (deploy function / import missing).

- [ ] **Step 3: Patch the smoke wrapper**

Add imports at the top of `playwright/osl-regression-smoke.spec.ts` with the other imports:

```typescript
import { registerTokenPropagationWorkflowTests } from "./specs/orchestrator-token-propagation.tests.js";
import { requireEnvVar } from "./support/utils/orchestrator-workflow-helpers.js";
```

After `registerOrchestratorCoreWorkflowTests(ensureDataIndexOrSkip);` always call:

```typescript
registerTokenPropagationWorkflowTests(requireEnvVar);
```

Do not gate this on an env var.

- [ ] **Step 4: Always deploy token-propagation from `ensure_smoke_workflows`**

Add `ensure_token_propagation_workflow` modeled on overlays `deployTokenPropagationWorkflow` in `rhdh-plugin-export-overlays/workspaces/orchestrator/e2e-tests/tests/support/utils/workflow-deployment-helpers.ts` (function starts ~line 460). Required behavior:

1. Require `KEYCLOAK_BASE_URL` (already exported in `phase_test` before `ensure_smoke_workflows`). If `ensure_smoke_workflows` runs before Keycloak env is set, set `KEYCLOAK_BASE_URL` first — `phase_test` already does this before `ensure_dataindex_rewrite`; move `ensure_smoke_workflows` so it runs **after** `KEYCLOAK_BASE_URL` is exported (it already does today).
2. `authServerUrl="${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_REALM}"` with realm `rhdh`.
3. `tokenUrl="${authServerUrl}/protocol/openid-connect/token"`.
4. Clone `https://github.com/rhdhorchestrator/orchestrator-demo.git` shallow into a temp dir.
5. Rewrite `09_token_propagation/manifests/01-configmap_token-propagation-props.yaml`:
   - `http://example-kc-service.keycloak:8080/realms/quarkus` → `$authServerUrl`
   - `client-id=quarkus-app` → `client-id=rhdh-client`
   - `client-secret=lVGSvdaoDUem7lqeAnqXn1F92dCPbQea` → `client-secret=rhdh-client-secret`
   - `http://sample-server-service.rhdh-operator` → `http://sample-server-service.${ns}:8080`
6. Rewrite `09_token_propagation/manifests/03-configmap_02-token-propagation-resources-specs.yaml` token URL to `$tokenUrl`.
7. Apply the sample-server Deployment/Service YAML from that overlays function (image `quay.io/orchestrator/sample-server:latest`), wait Available 120s.
8. `oc apply -n "$ns" -f "$manifestsDir"`.
9. Extend `patch_smoke_workflow` so `name=token-propagation` patches **persistence only** (do not change `podTemplate.container.image`; demo manifests already set it). Persistence JSON must match greeting: `backstage-psql-secret` / `POSTGRES_USER` / `POSTGRES_PASSWORD`, `serviceRef.name=backstage-psql`, `databaseName=backstage_plugin_orchestrator`, `databaseSchema=token-propagation`.
10. Include `token-propagation` in `wait_smoke_workflows_ready` alongside `greeting` and `failswitch` (all three must report `readyReplicas=1`).
11. `rm -rf` the clone.

At the end of `ensure_smoke_workflows`, after greeting/failswitch apply+patch, call:

```bash
ensure_token_propagation_workflow "$ns"
```

Keep a single wait loop that includes all three deployments. Probe (Task 2) stays after `ensure_smoke_workflows`, so token-propagation is Ready before GraphQL classify.

- [ ] **Step 5: README**

State that default smoke always deploys and runs token-propagation (JWT/OpenAPI into the workflow). Do not document `--include-token-propagation`.

- [ ] **Step 6: Run unit tests**

```bash
python3 utils/orchestrator/test_osl_smoke.py
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add run-osl-regression.sh playwright/osl-regression-smoke.spec.ts README.md \
  utils/orchestrator/test_osl_smoke.py
git commit -m "$(cat <<'EOF'
feat: include token-propagation in default OSL RC smoke #13375

EOF
)"
```

---

### Task 5: Makefile pass-through and verification notes

**Files:**
- Modify: `Makefile` (`osl-regression` target)

**Interfaces:**
- Consumes: `--allow-relative-service-url` from Task 2
- Produces: `make osl-regression` can pass `ALLOW_RELATIVE_SERVICE_URL=1`

- [ ] **Step 1: Extend `osl-regression`**

```make
osl-regression: ## Cleanup + prepare OSL + deploy + 4-test smoke (VERSION, OSL_RELEASE)
ifndef OSL_RELEASE
	$(error OSL_RELEASE is required, e.g. make osl-regression VERSION=next OSL_RELEASE=1.39.0.CR1)
endif
	./run-osl-regression.sh --all --rhdh $(VERSION) --osl-release $(OSL_RELEASE) --namespace $(ORCH_NAMESPACE) \
		$(if $(filter 1,$(ALLOW_RELATIVE_SERVICE_URL)),--allow-relative-service-url,)
```

- [ ] **Step 2: Dry-run help**

```bash
./run-osl-regression.sh --help
```

Expected: usage lists `--allow-relative-service-url`. It must **not** list `--include-token-propagation`.

- [ ] **Step 3: Commit**

```bash
git add Makefile README.md
git commit -m "$(cat <<'EOF'
docs: document OSL RC 4-test smoke including token-propagation #13375

EOF
)"
```

---

## Cluster verification (after Tasks 1–5, not a code task)

On a logged-in cluster with RHDH already up:

```bash
export PATH="/home/rlan/bin:$HOME/.local/bin:$PATH"
cd /home/rlan/redhat/rhdh-test-instance/.worktrees/rhidp-13375-osl-smoke
# 1.39.CR1 expected: probe exit 2 unless ALLOW_RELATIVE_SERVICE_URL=1
ALLOW_RELATIVE_SERVICE_URL=1 ./run-osl-regression.sh --test --namespace orchestrator
```

Expected Playwright: **4 passed** (not 10). The report must include `Execute token-propagation workflow via API` and must not list `Verify Workflow All Runs` as executed.

Do not treat this cluster run as part of the git tasks; it is the human/agent gate after the commits.

---

## Self-review

1. **Spec coverage:** 4-test default including token-propagation → Tasks 1, 3, 4. GraphQL probe → Task 2. `--full-e2e` as plugin suite → Task 3 README. Makefile → Task 5. Plugin `serviceUrl` productization → sibling plan, not this file.
2. **Placeholders:** none.
3. **Types:** bash `SMOKE_GREP` (four titles), probe exit 0/1/2, `--allow-relative-service-url` matches `ALLOW_RELATIVE_SERVICE_URL=1`. No `--include-token-propagation`. No Python helper modules.
