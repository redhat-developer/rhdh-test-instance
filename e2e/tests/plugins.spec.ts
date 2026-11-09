import { expect, test, type Page } from "@playwright/test";

/**
 * Plugin pages that are worth navigating to directly. Catalog and entity page
 * features (Kubernetes, Topology, Scorecard) are covered by the loaded-plugins
 * API check plus a manual pass on the entity page, because their UI depends on
 * catalog data.
 */
const ROUTES: Record<string, { path: string; heading: RegExp }> = {
  "bulk-import": { path: "/bulk-import", heading: /bulk import/i },
  lighthouse: { path: "/lighthouse", heading: /lighthouse/i },
  orchestrator: { path: "/orchestrator", heading: /workflow/i },
  rbac: { path: "/rbac", heading: /rbac|role/i },
  "intelligent-assistant": { path: "/intelligent-assistant", heading: /assistant/i },
};

const selectedPlugins = (process.env.EXPECT_PLUGINS ?? "")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean);

async function expectPluginPage(page: Page, path: string, heading: RegExp): Promise<void> {
  const response = await page.goto(path);
  expect(response?.status(), `${path} should not return an HTTP error`).toBeLessThan(400);
  await expect(page.getByRole("heading", { name: heading }).first()).toBeVisible({
    timeout: 60_000,
  });
}

test.describe("plugin pages", () => {
  for (const [plugin, route] of Object.entries(ROUTES)) {
    test(`${plugin} page renders`, async ({ page }) => {
      test.skip(
        !selectedPlugins.includes(plugin),
        `${plugin} is not enabled for this deployment`,
      );
      await expectPluginPage(page, route.path, route.heading);
    });
  }
});
