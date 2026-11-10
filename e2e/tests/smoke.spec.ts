import { expect, test } from "@playwright/test";

import { loadedPlugins } from "./helpers";

const list = (value: string | undefined): string[] =>
  (value ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);

const EXPECTED_PLUGINS = list(process.env.EXPECT_PLUGINS);
const ABSENT_PLUGINS = list(process.env.ABSENT_PLUGINS);

test.describe("unauthenticated", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("healthcheck responds", async ({ request }) => {
    const response = await request.get("/healthcheck");
    expect(response.status()).toBe(200);
    expect(await response.json()).toMatchObject({ status: "ok" });
  });

  test("sign-in page offers OIDC", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Select a sign-in method" })).toBeVisible({
      timeout: 120_000,
    });
    await expect(page.getByText("Sign in using OIDC")).toBeVisible();
  });
});

test.describe("authenticated", () => {
  test("loaded plugins match the deployment", async ({ page }) => {
    const plugins = await loadedPlugins(page);
    const matches = (name: string, expected: string): boolean =>
      name.toLowerCase().includes(expected.toLowerCase());

    for (const expected of EXPECTED_PLUGINS) {
      expect(
        plugins.some((name) => matches(name, expected)),
        `expected plugin '${expected}' in loaded plugins: ${plugins.join(", ")}`,
      ).toBe(true);
    }
    for (const absent of ABSENT_PLUGINS) {
      expect(
        plugins.some((name) => matches(name, absent)),
        `plugin '${absent}' should not be loaded: ${plugins.join(", ")}`,
      ).toBe(false);
    }
  });

  test("home page renders the RHDH homepage", async ({ page }) => {
    await page.goto("/");
    // page:home is disabled, so the RHDH homepage is the only Home destination
    // in the sidebar (the global header logo is also a Home link).
    await expect(
      page
        .getByRole("navigation", { name: "sidebar nav" })
        .getByRole("link", { name: "Home", exact: true }),
    ).toHaveCount(1, { timeout: 60_000 });
    // customizable: false renders the default widgets instead of the empty state.
    await expect(page.getByText("No widgets added")).toHaveCount(0);
  });

  test("global search is available", async ({ page }) => {
    await page.goto("/");
    const search = page.getByPlaceholder(/search/i).first();
    await expect(search).toBeVisible({ timeout: 60_000 });
    await search.fill("catalog");
  });

  test("user settings exposes the language selector", async ({ page }) => {
    await page.goto("/settings");
    await expect(page.getByText(/^language$/i).first()).toBeVisible({ timeout: 60_000 });
  });
});
