import { defineConfig } from 'vitest/config';

export default defineConfig({
  define: {
    APP_REVISION: JSON.stringify('vitest-test'),
    APP_VERSION: JSON.stringify('0.0.1'),
  },
  test: {
    environment: 'jsdom',
    include: ['src/sfs/**/*.test.ts'],
  },
});
