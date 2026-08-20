# Spec: Derive Orchestrator `serviceUrl` from Data Index `endpoint`

## Problem

OSL 1.39 Data Index `ProcessDefinitions.serviceUrl` is a relative path ([SRVLOGIC-1137](https://redhat.atlassian.net/browse/SRVLOGIC-1137)). The RHDH Orchestrator backend concatenates that value:

- execute: `POST ${serviceUrl}/${definitionId}`
- ping/schema: `GET ${serviceUrl}/management/processes/${definitionId}`
- abort/retrigger: `${serviceUrl}/management/processes/${definitionId}/instances/...`

A relative `serviceUrl` such as `/greeting` becomes a failed fetch on the RHDH pod. Ricardo Zanini (SRVLOGIC-1137): `endpoint` is correct; consumers should take the server origin from `endpoint`.

`rhdh-test-instance` currently hides this with `osl-di-rewrite`. That workaround must not stay as the product fix.

## Goal

In `@red-hat-developer-hub/backstage-plugin-orchestrator-backend`, after every GraphQL read of a process definition, set `serviceUrl` to an absolute HTTP(S) origin:

- If `serviceUrl` already starts with `http://` or `https://`, keep it.
- Else if `endpoint` is an absolute URL, set `serviceUrl` to `new URL(endpoint).origin`.
- Else leave `serviceUrl` undefined (existing “not available” errors).

## In scope

- `rhdh-plugins` workspace `workspaces/orchestrator`, plugin `orchestrator-backend` only.
- Unit tests for the helper and for `fetchWorkflowInfos` / `fetchWorkflowServiceUrls` mapping.

## Out of scope

- `rhdh-test-instance` rewrite removal (do that in a later PR after this plugin is in the catalog the smoke uses).
- Changing GraphQL queries beyond ensuring `endpoint` is already selected (it is, on `fetchWorkflowInfos` and `fetchWorkflowInfo`; `fetchWorkflowServiceUrls` must add `endpoint`).

## Constraints

- Do not break OSL ≤ 1.38 (absolute `serviceUrl` unchanged).
- Do not use the versioned path from `endpoint` for execute (plugin still posts to `{origin}/{id}`, not `{endpoint}`). SRVLOGIC-1124 is OSL-side; do not switch execute to `endpoint` in this change.
- Conventional commits; link SRVLOGIC-1137 / RHIDP-13375 in the PR description, not as a required Jira key in this repo unless the project uses GitHub issues.
