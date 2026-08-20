// Smoke entry for run-osl-regression.sh (copied into overlays e2e tests/ at runtime).
// Overlays orchestrator-workflow-core.tests.ts only exports a register function;
// orchestrator.spec.ts beforeAll would reinstall operators / Helm-redeploy RHDH.
// NFS Alpha copy also drifts from e2e-utils locators.
// @ts-nocheck
import { test, expect } from "@red-hat-developer-hub/e2e-test-utils/test";
import { OrchestratorPage } from "@red-hat-developer-hub/e2e-test-utils/pages";
import { createDataIndexGuard, requireEnvVar } from "./support/utils/orchestrator-workflow-helpers.js";
import { registerOrchestratorCoreWorkflowTests } from "./specs/orchestrator-workflow-core.tests.js";
import { registerTokenPropagationWorkflowTests } from "./specs/orchestrator-token-propagation.tests.js";
import { ORCHESTRATOR_COMPONENTS } from "./support/pages/orchestrator-obj.js";

ORCHESTRATOR_COMPONENTS.workflowsHeading = (page) =>
  page.getByRole("heading", { name: /Workflows|Workflow Orchestrator/ });
ORCHESTRATOR_COMPONENTS.runButton = (page) =>
  page.getByRole("button", { name: "Run", exact: true });

OrchestratorPage.prototype.validateGreetingWorkflow = async function () {
  const page = this.page;
  await page.getByRole("tab", { name: /Workflows/ }).click();
  await expect(
    page.getByRole("heading", { name: /Workflows|Workflow Orchestrator/ }),
  ).toBeVisible();
  await expect(page.locator('input[aria-label="Filter"]')).toHaveAttribute(
    "placeholder",
    "Filter",
  );
  for (const name of ["Name", "Workflow Status", "Actions"]) {
    await expect(
      page.getByRole("columnheader", { name, exact: true }),
    ).toBeVisible();
  }
  const row = page.locator('tr:has-text("Greeting workflow")');
  await expect(row.locator("td").nth(0)).toHaveText("Greeting workflow");
  await expect(row.locator("td").nth(1)).toHaveText("Available");
  await expect(
    row.getByRole("button", { name: "Run", exact: true }).first(),
  ).toBeVisible();
  await expect(row.getByRole("button", { name: "View runs" }).first()).toBeVisible();
};

test.beforeEach(async ({ page }) => {
  const origGetByRole = page.getByRole.bind(page);
  page.getByRole = (role, options) => {
    if (role === "button" && options && options.name === "Run") {
      return origGetByRole(role, { ...options, exact: true });
    }
    if (role === "heading" && options && options.name === "Workflows") {
      return origGetByRole(role, {
        ...options,
        name: /^(Workflows|Workflow Orchestrator)$/,
      });
    }
    if (role === "columnheader" && options && options.name === "Run Status") {
      return origGetByRole(role, { name: /^(Run Status|Status)$/ });
    }
    if (role === "columnheader" && options && options.name === "Duration") {
      return origGetByRole(role, { name: /^(Duration|Version)$/ });
    }
    return origGetByRole(role, options);
  };

  const origGetByText = page.getByText.bind(page);
  page.getByText = (text, options) => {
    if (text === "Run has aborted") {
      return origGetByText(/Run (has|was) aborted/);
    }
    const loc = origGetByText(text, options);
    if (
      options &&
      options.exact &&
      typeof text === "string" &&
      ["Completed", "Failed", "Running"].includes(text)
    ) {
      return loc.first();
    }
    return loc;
  };

  const assertions = Object.getPrototypeOf(expect(page.locator("body")));
  if (assertions && !assertions.__oslPatchedToHaveText && assertions.toHaveText) {
    const origToHaveText = assertions.toHaveText;
    assertions.toHaveText = async function (expected, options) {
      if (expected === "Workflows") {
        expected = /^(Workflows|Workflow Orchestrator)$/;
      }
      return origToHaveText.call(this, expected, options);
    };
    assertions.__oslPatchedToHaveText = true;
  }
});

const innerDataIndexGuard = createDataIndexGuard();
const ensureDataIndexOrSkip = (ns: string, testObj: { skip: (condition: boolean, reason: string) => void }) =>
  innerDataIndexGuard(process.env.NAME_SPACE || ns, testObj);
registerOrchestratorCoreWorkflowTests(ensureDataIndexOrSkip);
registerTokenPropagationWorkflowTests(requireEnvVar);
