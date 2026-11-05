import { defineConfig } from 'vitest/config';

export default defineConfig({
  // Tests run the Chrome build; Firefox paths are tested through their parameters.
  define: { __TARGET__: JSON.stringify('chrome') },
  test: { environment: 'node', globals: true },
});
