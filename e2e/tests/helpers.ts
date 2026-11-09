import { expect, type Page } from "@playwright/test";

export const RHDH_USER = process.env.RHDH_USER ?? "test1";
export const RHDH_PASSWORD = process.env.RHDH_PASSWORD ?? "test1@123";

/**
 * Signs in through the RHDH sign-in page and the Keycloak popup.
 * Mirrors the flow used by the RHDH e2e suite: "Select a sign-in method" ->
 * "Sign In" button -> Keycloak popup (#username / #password / [name=login]).
 */
export async function signIn(page: Page, username = RHDH_USER, password = RHDH_PASSWORD): Promise<void> {
  await page.goto("/");

  const heading = page.getByRole("heading", { name: "Select a sign-in method" });
  await expect(heading).toBeVisible({ timeout: 120_000 });
  await expect(page.getByText("Sign in using OIDC")).toBeVisible();

  const [popup] = await Promise.all([
    page.waitForEvent("popup"),
    page.getByRole("button", { name: "Sign In", exact: true }).click(),
  ]);

  await popup.waitForLoadState("domcontentloaded");

  // Keycloak reuses the SSO session when one already exists.
  if (await popup.locator("#username").isVisible().catch(() => false)) {
    await popup.locator("#username").fill(username);
    await popup.locator("#password").fill(password);
    await popup.locator("[name=login]").click();
  }

  await popup.waitForEvent("close", { timeout: 60_000 }).catch(() => {});
  await expect(heading).toBeHidden({ timeout: 60_000 });
}

/** Returns the Backstage identity token for the signed-in browser session. */
export async function authToken(page: Page): Promise<string> {
  for (const env of ["production", "development", ""]) {
    const response = await page.request.get(`/api/auth/oidc/refresh?optional=&scope=&env=${env}`, {
      headers: { "x-requested-with": "XMLHttpRequest" },
    });
    if (!response.ok()) {
      continue;
    }
    const body: unknown = await response.json();
    const token =
      typeof body === "object" && body !== null && "backstageIdentity" in body
        ? (body as { backstageIdentity?: { token?: unknown } }).backstageIdentity?.token
        : undefined;
    if (typeof token === "string" && token.length > 0) {
      return token;
    }
  }
  throw new Error("Could not obtain a Backstage token from /api/auth/oidc/refresh");
}

/** Package names reported by the dynamic-plugins-info backend. */
export async function loadedPlugins(page: Page): Promise<string[]> {
  const token = await authToken(page);
  const response = await page.request.get("/api/dynamic-plugins-info/loaded-plugins", {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(response.ok(), "GET /api/dynamic-plugins-info/loaded-plugins").toBeTruthy();
  const body: unknown = await response.json();
  if (!Array.isArray(body)) {
    throw new Error("loaded-plugins did not return an array");
  }
  return body.map((plugin) => {
    const entry = plugin as { name?: unknown; pluginId?: unknown };
    return String(entry.name ?? entry.pluginId ?? "");
  });
}
