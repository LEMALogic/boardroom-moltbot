import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright configuration for Boardroom Command Center E2E tests.
 *
 * Design decisions:
 * - forbidOnly: true - Prevents .only() from being committed (catches CI issues early)
 * - retries: 0 - Forces fixing flaky tests rather than masking them
 * - workers: 1 - Sequential execution for real LLM tests (avoids rate limits, resource contention)
 * - timeout: 60000ms - Generous timeout for LLM response latency
 */
export default defineConfig({
  testDir: './e2e',

  /* Run tests in files in parallel */
  fullyParallel: false,

  /* Fail the build on CI if you accidentally left test.only in the source code */
  forbidOnly: true,

  /* No retries - fix the test or the code */
  retries: 0,

  /* Single worker for real LLM tests */
  workers: 1,

  /* Reporter configuration */
  reporter: [
    ['list'],
    ['html', { open: 'never' }]
  ],

  /* Shared settings for all the projects below */
  use: {
    /* Base URL for navigation */
    baseURL: 'http://localhost:18789',

    /* Collect trace when retrying the failed test */
    trace: 'on-first-retry',

    /* Screenshot on failure */
    screenshot: 'only-on-failure',
  },

  /* Global timeout for each test */
  timeout: 60000,

  /* Configure projects for major browsers */
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
