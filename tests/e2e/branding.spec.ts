import { test, expect } from '@playwright/test';

/**
 * Branding verification tests for Boardroom Command Center.
 *
 * These tests ensure no legacy or internal branding terms appear
 * in the production application.
 */

test.describe('Branding Verification', () => {

  test('should have NO original branding anywhere', async ({ page }) => {
    await page.goto('/');

    // Wait for page to fully load
    await page.waitForLoadState('networkidle');

    // Get all text content from the page
    const pageContent = await page.textContent('body');

    // Forbidden branding terms - case variations
    const forbiddenTerms = [
      // clawdbot variations
      'clawdbot',
      'CLAWDBOT',
      'Clawdbot',
      'ClawdBot',
      // moltbot variations
      'moltbot',
      'MOLTBOT',
      'Moltbot',
      'MoltBot',
      // molty variations
      'molty',
      'MOLTY',
      'Molty',
      // domain variations
      'clawd.bot',
      'molt.bot',
    ];

    // Check each forbidden term
    for (const term of forbiddenTerms) {
      expect(
        pageContent,
        `Page should not contain forbidden branding term: "${term}"`
      ).not.toContain(term);
    }
  });

  test('page title should be "Boardroom Command Center"', async ({ page }) => {
    await page.goto('/');

    // Wait for page to fully load
    await page.waitForLoadState('networkidle');

    // Verify the page title
    await expect(page).toHaveTitle('Boardroom Command Center');
  });

});
