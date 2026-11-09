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

  test("home page renders without duplicate search boxes", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("h1, h2").first()).toBeVisible({ timeout: 60_000 });

    // The Backstage search plugin's home widget duplicates the RHDH homepage
    // search bar on 1.54 and is disabled in the base configuration.
    expect(await page.getByRole("textbox").count()).toBeLessThanOrEqual(1);
  });

  test("sidebar search is not hidden", async ({ page }) => {
    await page.goto("/");
    const search = page
      .getByRole("link", { name: /search/i })
      .or(page.getByRole("button", { name: /search/i }))
      .first();
    await expect(search).toBeVisible({ timeout: 60_000 });
  });

  test("user settings exposes the language selector", async ({ page }) => {
    await page.goto("/settings");
    await expect(page.getByText(/^language$/i).first()).toBeVisible({ timeout: 60_000 });
  });
});
