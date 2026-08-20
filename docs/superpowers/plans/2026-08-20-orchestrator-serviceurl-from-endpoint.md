# Orchestrator serviceUrl-from-endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Orchestrator backend treat OSL 1.39 relative Data Index `serviceUrl` as the origin of `endpoint`, so execute/abort/retrigger work without `osl-di-rewrite`.

**Architecture:** Add a pure helper `resolveWorkflowServiceUrl`, unit-test it, then apply it to every `ProcessDefinitions` mapping in `DataIndexService`. Do not change the execute URL shape (`${origin}/${id}`).

**Tech Stack:** TypeScript, Jest via `yarn test` in `rhdh-plugins/workspaces/orchestrator`.

**Spec:** `docs/superpowers/specs/2026-08-20-orchestrator-serviceurl-from-endpoint.md` (this worktree copy). Implement in **`rhdh-plugins`**, not in `rhdh-test-instance`.

## Global Constraints

- Implementation repo: `rhdh-plugins`, workspace `workspaces/orchestrator`. Create a new branch from that repo’s default (do not commit plugin code into `rhdh-test-instance`).
- Do not mix this PR with the OSL smoke-driver PR.
- Keep absolute `http://` / `https://` `serviceUrl` values unchanged (OSL ≤ 1.38).
- Do not POST to the full `endpoint` path; only copy `.origin`.
- `fetchWorkflowServiceUrls` currently queries `{ id, serviceUrl }` only — it **must** also fetch `endpoint`.

---

## File map

| File | Responsibility |
|---|---|
| `plugins/orchestrator-backend/src/service/workflowServiceUrl.ts` | `isAbsoluteHttpUrl`, `resolveWorkflowServiceUrl` |
| `plugins/orchestrator-backend/src/service/workflowServiceUrl.test.ts` | Jest cases for relative / absolute / bad endpoint |
| `plugins/orchestrator-backend/src/service/DataIndexService.ts` | Apply helper on definition reads; add `endpoint` to `fetchWorkflowServiceUrls` query |
| `plugins/orchestrator-backend/src/service/DataIndexService.test.ts` | Assert mapping when GraphQL returns relative `serviceUrl` |

Paths are relative to `/home/rlan/redhat/rhdh-plugins/workspaces/orchestrator`.

---

### Task 1: Helper + unit tests

**Files:**
- Create: `plugins/orchestrator-backend/src/service/workflowServiceUrl.ts`
- Create: `plugins/orchestrator-backend/src/service/workflowServiceUrl.test.ts`

**Interfaces:**
- Consumes: none
- Produces:
  - `isAbsoluteHttpUrl(value?: string): boolean`
  - `resolveWorkflowServiceUrl(info: { serviceUrl?: string; endpoint?: string }): string | undefined`

- [ ] **Step 1: Confirm branch in rhdh-plugins**

```bash
git -C /home/rlan/redhat/rhdh-plugins branch --show-current
git -C /home/rlan/redhat/rhdh-plugins status -sb
```

If the tree is dirty or the branch is not a new feature branch, create one:

```bash
git -C /home/rlan/redhat/rhdh-plugins fetch origin
git -C /home/rlan/redhat/rhdh-plugins switch -c fix/orchestrator-serviceurl-from-endpoint origin/main
```

(Use the actual default remote/branch if it is not `origin/main`.)

- [ ] **Step 2: Write the failing test**

Create `plugins/orchestrator-backend/src/service/workflowServiceUrl.test.ts`:

```typescript
import {
  isAbsoluteHttpUrl,
  resolveWorkflowServiceUrl,
} from './workflowServiceUrl';

describe('isAbsoluteHttpUrl', () => {
  it('accepts http and https', () => {
    expect(isAbsoluteHttpUrl('http://greeting.ns.svc')).toBe(true);
    expect(isAbsoluteHttpUrl('https://greeting.example')).toBe(true);
  });

  it('rejects relative, empty, and non-http', () => {
    expect(isAbsoluteHttpUrl('/greeting')).toBe(false);
    expect(isAbsoluteHttpUrl('greeting.ns.svc')).toBe(false);
    expect(isAbsoluteHttpUrl('')).toBe(false);
    expect(isAbsoluteHttpUrl(undefined)).toBe(false);
  });
});

describe('resolveWorkflowServiceUrl', () => {
  it('keeps an already-absolute serviceUrl', () => {
    expect(
      resolveWorkflowServiceUrl({
        serviceUrl: 'http://greeting.orchestrator.svc',
        endpoint: 'http://other.svc/greeting/1.0.0',
      }),
    ).toBe('http://greeting.orchestrator.svc');
  });

  it('uses endpoint origin when serviceUrl is relative (SRVLOGIC-1137)', () => {
    expect(
      resolveWorkflowServiceUrl({
        serviceUrl: '/greeting',
        endpoint: 'http://greeting.orchestrator.svc.cluster.local/greeting/1.0.0',
      }),
    ).toBe('http://greeting.orchestrator.svc.cluster.local');
  });

  it('uses endpoint origin when serviceUrl is missing', () => {
    expect(
      resolveWorkflowServiceUrl({
        endpoint: 'http://failswitch.orchestrator.svc/failswitch',
      }),
    ).toBe('http://failswitch.orchestrator.svc');
  });

  it('returns undefined when neither field is a usable URL', () => {
    expect(resolveWorkflowServiceUrl({ serviceUrl: '/greeting' })).toBeUndefined();
    expect(resolveWorkflowServiceUrl({})).toBeUndefined();
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd /home/rlan/redhat/rhdh-plugins/workspaces/orchestrator
yarn test plugins/orchestrator-backend --testPathPattern=workflowServiceUrl.test --coverage=false
```

Expected: FAIL (cannot resolve `./workflowServiceUrl`).

- [ ] **Step 4: Write the helper**

Create `plugins/orchestrator-backend/src/service/workflowServiceUrl.ts`:

```typescript
export function isAbsoluteHttpUrl(value?: string): boolean {
  if (!value) {
    return false;
  }
  return value.startsWith('http://') || value.startsWith('https://');
}

export function resolveWorkflowServiceUrl(info: {
  serviceUrl?: string;
  endpoint?: string;
}): string | undefined {
  if (isAbsoluteHttpUrl(info.serviceUrl)) {
    return info.serviceUrl;
  }
  if (!info.endpoint) {
    return undefined;
  }
  try {
    return new URL(info.endpoint).origin;
  } catch {
    return undefined;
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /home/rlan/redhat/rhdh-plugins/workspaces/orchestrator
yarn test plugins/orchestrator-backend --testPathPattern=workflowServiceUrl.test --coverage=false
```

Expected: PASS.

- [ ] **Step 6: Commit in rhdh-plugins**

```bash
cd /home/rlan/redhat/rhdh-plugins
git add workspaces/orchestrator/plugins/orchestrator-backend/src/service/workflowServiceUrl.ts \
  workspaces/orchestrator/plugins/orchestrator-backend/src/service/workflowServiceUrl.test.ts
git commit -m "$(cat <<'EOF'
feat: add workflow serviceUrl origin helper for OSL 1.39 Data Index

EOF
)"
```

---

### Task 2: Apply the helper in DataIndexService

**Files:**
- Modify: `plugins/orchestrator-backend/src/service/DataIndexService.ts`
- Modify: `plugins/orchestrator-backend/src/service/DataIndexService.test.ts`

**Interfaces:**
- Consumes: `resolveWorkflowServiceUrl` from Task 1
- Produces: every returned `WorkflowInfo` (and `fetchWorkflowServiceUrls` map values) has an absolute `serviceUrl` when `endpoint` is absolute

- [ ] **Step 1: Write a failing DataIndexService test**

In `DataIndexService.test.ts`, add a `describe('relative serviceUrl from OSL 1.39')` that mocks `client.query` for `fetchWorkflowInfos` (no definitionIds/filter) returning:

```javascript
{
  data: {
    ProcessDefinitions: [
      {
        id: 'greeting',
        name: 'Greeting',
        serviceUrl: '/greeting',
        endpoint: 'http://greeting.orchestrator.svc/greeting',
        metadata: {},
      },
    ],
  },
  error: undefined,
}
```

Assert `infos[0].serviceUrl === 'http://greeting.orchestrator.svc'`.

Follow the existing `fetchWorkflowInfos` mock style in that file (`mockClient.query`, `Client` mock, `loggerMock`). Keep `filterDeletedWorkflows` behavior: `metadata.status === 'unavailable'` still dropped.

Add a second test for `fetchWorkflowServiceUrls`: mock GraphQL data with relative `serviceUrl` + absolute `endpoint`; expect the returned map `{ greeting: 'http://greeting.orchestrator.svc' }`. This test **must fail** until the query string includes `endpoint`.

- [ ] **Step 2: Run the new tests to verify fail**

```bash
cd /home/rlan/redhat/rhdh-plugins/workspaces/orchestrator
yarn test plugins/orchestrator-backend --testPathPattern=DataIndexService.test --coverage=false
```

Expected: FAIL — `serviceUrl` still `'/greeting'`.

- [ ] **Step 3: Implement mapping**

At top of `DataIndexService.ts`:

```typescript
import { resolveWorkflowServiceUrl } from './workflowServiceUrl';
```

Add a private method:

```typescript
private withResolvedServiceUrl(info: WorkflowInfo): WorkflowInfo {
  return {
    ...info,
    serviceUrl: resolveWorkflowServiceUrl(info),
  };
}
```

Apply it:

- `fetchWorkflowInfo`: `return this.withResolvedServiceUrl(processDefinitions[0]);`
- `fetchWorkflowInfos`: `return this.filterDeletedWorkflows(...).map(w => this.withResolvedServiceUrl(w));`
- `fetchWorkflowServiceUrls`: change query to `{ ProcessDefinitions { id, serviceUrl, endpoint } }`, then:

```typescript
return processDefinitions
  .map(definition => this.withResolvedServiceUrl(definition))
  .filter(definition => definition.serviceUrl)
  .map(definition => ({ [definition.id]: definition.serviceUrl! }))
  .reduce((acc, curr) => ({ ...acc, ...curr }), {});
```

Do not change execute/abort URL builders in `SonataFlowService.ts`; they already use the resolved `serviceUrl`.

- [ ] **Step 4: Run DataIndexService + helper tests**

```bash
cd /home/rlan/redhat/rhdh-plugins/workspaces/orchestrator
yarn test plugins/orchestrator-backend --testPathPattern='workflowServiceUrl.test|DataIndexService.test' --coverage=false
```

Expected: PASS.

- [ ] **Step 5: Commit in rhdh-plugins**

```bash
git add workspaces/orchestrator/plugins/orchestrator-backend/src/service/DataIndexService.ts \
  workspaces/orchestrator/plugins/orchestrator-backend/src/service/DataIndexService.test.ts
git commit -m "$(cat <<'EOF'
fix: derive Data Index serviceUrl origin from endpoint

EOF
)"
```

---

### Task 3: Do not remove the test-instance rewrite in this PR

No code. After the plugin is in the RHDH `next` catalog image the smoke uses, a **later** `rhdh-test-instance` change can skip `ensure_dataindex_rewrite` and drop `--allow-relative-service-url`. Mixing that into this plugin PR will break smoke until the image exists.

---

## Self-review

1. **Spec coverage:** helper + mapping + `fetchWorkflowServiceUrls` query includes `endpoint` → Tasks 1–2. Rewrite removal → Task 3 (explicitly deferred). Execute still uses origin, not versioned endpoint → Task 2 note.
2. **Placeholders:** none.
3. **Names:** `resolveWorkflowServiceUrl` / `withResolvedServiceUrl` used consistently.
