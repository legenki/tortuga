import { defineConfig } from 'vite';
import { resolve } from 'path';
import { define, outDir } from './vite.target';

export default defineConfig({
  define,
  build: {
    outDir,
    // First of the three builds: start from a clean dist so removed files don't ship.
    emptyOutDir: true,
    lib: {
      entry: resolve(__dirname, 'src/background/index.ts'),
      formats: ['es'],
      fileName: () => 'background.js',
    },
    rollupOptions: { external: [] },
  },
});
