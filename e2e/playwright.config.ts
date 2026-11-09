import { defineConfig, devices } from "@playwright/test";

const baseURL = process.env.RHDH_BASE_URL;
if (!baseURL) {
  throw new Error("RHDH_BASE_URL is required (use make smoke or export it explicitly).");
}

export default defineConfig({
  testDir: "./tests",
  timeout: 180_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"]],
  outputDir: "results",
  use: {
    baseURL,
    ignoreHTTPSErrors: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    viewport: { width: 1440, height: 900 },
  },
  projects: [
    // Signs in through Keycloak once and stores the session for the other tests.
    { name: "setup", testMatch: /auth\.setup\.ts/ },
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        storageState: "results/.auth/state.json",
      },
      dependencies: ["setup"],
    },
  ],
});
