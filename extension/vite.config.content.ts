import { defineConfig } from 'vite';
import { resolve } from 'path';
import { define, outDir } from './vite.target.ts';

// Content scripts can't be ES modules: links.js is one IIFE bundle.
export default defineConfig({
  publicDir: false,
  define,
  build: {
    outDir,
    emptyOutDir: false,
    lib: { entry: resolve(import.meta.dirname, 'src/content/links.ts'), formats: ['iife'], name: 'tortugaLinks', fileName: () => 'links.js' },
  },
});
