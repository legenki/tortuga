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
      input: { confirm: resolve(import.meta.dirname, 'src/confirm/index.html') },
      output: { entryFileNames: '[name].js', assetFileNames: '[name].[ext]' },
    },
  },
  plugins: [
    {
      name: 'flatten-confirm-html',
      closeBundle() {
        // Vite mirrors the source path (dist/src/confirm/index.html); the window opens dist/confirm.html.
        renameSync(resolve(import.meta.dirname, outDir, 'src/confirm/index.html'), resolve(import.meta.dirname, outDir, 'confirm.html'));
        rmSync(resolve(import.meta.dirname, outDir, 'src'), { recursive: true, force: true });
      },
    },
  ],
});
