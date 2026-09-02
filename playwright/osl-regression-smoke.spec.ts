// Smoke entry for run-osl-regression.sh (copied into overlays e2e tests/ at runtime).
// Overlays orchestrator-workflow-core.tests.ts only exports a register function;
// orchestrator.spec.ts beforeAll would reinstall operators / Helm-redeploy RHDH.
//
// NFS lane (orchestrator-app-next) drives most UI via overlays OrchestratorPO.
// Grep still hits a few e2e-utils OrchestratorPage helpers that match "Run"
// without exact:true (ambiguous with "Run again").
// @ts-nocheck
import { test } from "@red-hat-developer-hub/e2e-test-utils/test";
import { createDataIndexGuard, requireEnvVar } from "./support/utils/orchestrator-workflow-helpers.js";
import { registerOrchestratorCoreWorkflowTests } from "./specs/orchestrator-workflow-core.tests.js";
import { registerTokenPropagationWorkflowTests } from "./specs/orchestrator-token-propagation.tests.js";

test.beforeEach(async ({ page }) => {
  const origGetByRole = page.getByRole.bind(page);
  page.getByRole = (role, options) => {
    if (role === "button" && options && options.name === "Run" && !options.exact) {
      return origGetByRole(role, { ...options, exact: true });
    }
    return origGetByRole(role, options);
  };
});

const innerDataIndexGuard = createDataIndexGuard();
const ensureDataIndexOrSkip = (ns: string, testObj: { skip: (condition: boolean, reason: string) => void }) =>
  innerDataIndexGuard(process.env.NAME_SPACE || ns, testObj);
registerOrchestratorCoreWorkflowTests(ensureDataIndexOrSkip);
registerTokenPropagationWorkflowTests(requireEnvVar);
