import { defineConfig } from 'vite';
import { resolve } from 'path';
import { define, outDir } from './vite.target.ts';

// theme.js runs as a classic script in the popup's <head>, before the first paint.
export default defineConfig({
  publicDir: false,
  define,
  build: {
    outDir,
    emptyOutDir: false,
    lib: { entry: resolve(import.meta.dirname, 'src/lib/theme-boot.ts'), formats: ['iife'], name: 'theme', fileName: () => 'theme.js' },
  },
});
