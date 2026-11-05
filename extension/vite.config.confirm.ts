import { defineConfig } from 'vite';
import { resolve } from 'path';
import { renameSync, rmSync } from 'fs';
import { define, outDir } from './vite.target';

export default defineConfig({
  define,
  build: {
    outDir,
    emptyOutDir: false,
    rollupOptions: {
      input: { confirm: resolve(__dirname, 'src/confirm/index.html') },
      output: { entryFileNames: '[name].js', assetFileNames: '[name].[ext]' },
    },
  },
  plugins: [
    {
      name: 'flatten-confirm-html',
      closeBundle() {
        // Vite mirrors the source path (dist/src/confirm/index.html); the window opens dist/confirm.html.
        renameSync(resolve(__dirname, outDir, 'src/confirm/index.html'), resolve(__dirname, outDir, 'confirm.html'));
        rmSync(resolve(__dirname, outDir, 'src'), { recursive: true, force: true });
      },
    },
  ],
});
