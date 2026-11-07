import { defineConfig } from 'vite';
import { resolve } from 'path';
import { define, outDir, treeshake } from './vite.target.ts';

export default defineConfig({
  define,
  build: {
    outDir,
    // First of the three builds: start from a clean dist so removed files don't ship.
    emptyOutDir: true,
    lib: {
      entry: resolve(import.meta.dirname, 'src/background/index.ts'),
      formats: ['es'],
      fileName: () => 'background.js',
    },
    rollupOptions: { external: [], treeshake },
  },
});
