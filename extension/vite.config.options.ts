import { defineConfig } from 'vite';
import { resolve } from 'path';
import { renameSync, rmSync } from 'fs';
import { define, outDir } from './vite.target.ts';

export default defineConfig({
  define,
  build: {
    outDir,
    emptyOutDir: false,
    rollupOptions: {
      input: { options: resolve(import.meta.dirname, 'src/options/index.html') },
      output: { entryFileNames: '[name].js', assetFileNames: '[name].[ext]' },
    },
  },
  plugins: [
    {
      name: 'flatten-options-html',
      closeBundle() {
        // Vite mirrors the source path (dist/src/options/index.html); the manifest wants dist/options.html.
        renameSync(resolve(import.meta.dirname, outDir, 'src/options/index.html'), resolve(import.meta.dirname, outDir, 'options.html'));
        rmSync(resolve(import.meta.dirname, outDir, 'src'), { recursive: true, force: true });
      },
    },
  ],
});
