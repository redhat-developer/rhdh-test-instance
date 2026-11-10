import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Plugin pages that are worth navigating to directly. Catalog and entity page
 * features (Kubernetes, Topology, Scorecard) are covered by the loaded-plugins
 * API check plus a manual pass on the entity page, because their UI depends on
 * catalog data.
 */
const ROUTES: Record<string, { path: string; check: (page: Page) => Locator }> = {
  "bulk-import": {
    path: "/bulk-import",
    check: (page) => page.getByRole("heading", { name: /bulk import/i }),
  },
  lighthouse: {
    path: "/lighthouse",
    check: (page) => page.getByRole("heading", { name: /lighthouse/i }),
  },
  orchestrator: {
    path: "/orchestrator",
    check: (page) => page.getByRole("heading", { name: /workflow/i }),
  },
  rbac: {
    path: "/rbac",
    check: (page) => page.getByRole("heading", { name: /rbac|role/i }),
  },
  "intelligent-assistant": {
    path: "/intelligent-assistant",
    // The page title is a visually hidden h1; the setup card carries the
    // visible plugin name in its actions.
    check: (page) => page.getByText(/intelligent assistant/i).filter({ visible: true }),
  },
};

const selectedPlugins = (process.env.EXPECT_PLUGINS ?? "")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean);

async function expectPluginPage(
  page: Page,
  path: string,
  check: (page: Page) => Locator,
): Promise<void> {
  const response = await page.goto(path);
  expect(response?.status(), `${path} should not return an HTTP error`).toBeLessThan(400);
  await expect(check(page).first()).toBeVisible({ timeout: 60_000 });
}

test.describe("plugin pages", () => {
  for (const [plugin, route] of Object.entries(ROUTES)) {
    test(`${plugin} page renders`, async ({ page }) => {
      test.skip(
        !selectedPlugins.includes(plugin),
        `${plugin} is not enabled for this deployment`,
      );
      await expectPluginPage(page, route.path, route.check);
    });
  }
});
