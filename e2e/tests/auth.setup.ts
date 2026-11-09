import { mkdirSync } from "node:fs";

import { expect, test as setup } from "@playwright/test";

import { RHDH_PASSWORD, RHDH_USER, authToken, signIn } from "./helpers";

setup("sign in through Keycloak", async ({ page }) => {
  await signIn(page, RHDH_USER, RHDH_PASSWORD);

  // Fail here rather than in every test if the session is not usable.
  const token = await authToken(page);
  expect(token.length).toBeGreaterThan(0);

  mkdirSync("results/.auth", { recursive: true });
  await page.context().storageState({ path: "results/.auth/state.json" });
});
