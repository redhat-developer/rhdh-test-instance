# Spec: OSL RC smoke subset (RHIDP-13375)

Research for this spec: RHIDP-13375, RHDH 1.10 Orchestrator docs, OSL 1.37–1.38 release notes, SRVLOGIC-1137 / SRVLOGIC-1124, and the Orchestrator backend execute path (`POST {serviceUrl}/{id}` plus `/management/processes/...`).

## Problem

`./run-osl-regression.sh --test` used to copy `playwright/osl-regression-smoke.spec.ts` into overlays e2e and run **all 10** `registerOrchestratorCoreWorkflowTests` cases. That is more Playwright than an OSL CR gate needs: abort / status-detail / All Runs / suggested-link duplicate Failswitch OSL APIs and mostly assert RHDH UI. A single Greeting execute is **not** enough either: it misses Jobs Service timers, abort, switch/error, retrigger, and JWT/OpenAPI auth into the workflow runtime.

OSL 1.39.CR1 also changed Data Index `ProcessDefinitions.serviceUrl` to a relative path (SRVLOGIC-1137). The current `osl-di-rewrite` proxy hides that from Playwright. There is no pre-Playwright check against the **raw** Data Index.

## Goal

Make the default OSL RC path (`--all` / `make osl-regression`) a **lean OSL contract + workflow gate**:

1. Probe raw Data Index GraphQL before Playwright.
2. Run exactly four Playwright tests (Greeting, Failswitch statuses, Failswitch retrigger, token-propagation).

## In scope (this repo: `rhdh-test-instance`)

- `run-osl-regression.sh` wiring: raw Data Index GraphQL probe (`jq`), default Playwright `--grep` of the four titles, `--allow-relative-service-url`.
- Smoke wrapper always registers token-propagation tests (no env flag).
- Always deploy `sample-server` + `token-propagation` on the smoke path (same Keycloak substitutions overlays uses).
- README / Makefile copy.

## Out of scope (separate plan)

- Changing Orchestrator plugin code to derive `serviceUrl` origin from `endpoint`.
- Removing `osl-di-rewrite` (only after the plugin ships).
- Editing `rhdh-plugin-export-overlays` test files in git (runtime copy of the smoke wrapper stays).

## Default Playwright titles

Exact strings from overlays specs:

1. `Run Greeting workflow and verify Workflows tab`
2. `Run Failswitch workflow and verify statuses`
3. `Rerun Failswitch from failure point`
4. `Execute token-propagation workflow via API`

## GraphQL probe

- Query **raw** `http://sonataflow-platform-data-index-service.<ns>.svc.cluster.local/graphql` from inside the cluster (RHDH pod `curl`), **not** `osl-di-rewrite`.
- Query body: `{ ProcessDefinitions { id serviceUrl endpoint } }`.
- A `serviceUrl` is valid only if it starts with `http://` or `https://`.
- If any definition has a missing or relative `serviceUrl`, exit **2** unless `ALLOW_RELATIVE_SERVICE_URL=1` / `--allow-relative-service-url` (then print a warning and continue so Playwright can still run behind the rewrite proxy).
- If the query fails or returns zero definitions after smoke workflows are Ready, exit **1**.

## Token-propagation (always on for smoke)

Default `--test` / `--all` always:

- Deploys `sample-server` and `token-propagation` from `https://github.com/rhdhorchestrator/orchestrator-demo.git` path `09_token_propagation/manifests`, with the same Keycloak URL substitutions overlays uses.
- Registers overlays `Execute token-propagation workflow via API` in the smoke wrapper (unconditional).
- Includes that title in the Playwright grep.
- Waits for `deployment/token-propagation` Ready before the GraphQL probe.

There is no `--include-token-propagation` or `--full-e2e` flag. `--cleanup` always removes operators, catalog, and mirror (the former `--include-operators` behavior).

## `--allow-relative-service-url`

OSL 1.39.CR1 Data Index can return a relative `ProcessDefinitions.serviceUrl` (SRVLOGIC-1137). The Orchestrator plugin then cannot execute/abort/retrigger workflows. The smoke probe queries **raw** Data Index and exits 2 on that contract break. Pass `--allow-relative-service-url` or `ALLOW_RELATIVE_SERVICE_URL=1` to warn and continue so Playwright can still run behind `osl-di-rewrite`. Remove the override after the plugin derives `serviceUrl` from `endpoint`.

## Constraints

- Do not commit `.env`, `.env.osl`, cluster passwords, or Keycloak secrets.
- Do not edit files outside `rhdh-test-instance` for this spec.
- Driver is bash (`run-osl-regression.sh`). Classify GraphQL with `jq`. Do not add Python helper modules.
- `oc` / `helm` may live in `/home/rlan/bin`; driver already assumes they are on `PATH`.
- Conventional commits; reference `#13375`.
