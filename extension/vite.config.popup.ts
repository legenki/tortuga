import { defineConfig } from 'vite';
import { resolve } from 'path';
import { copyFileSync, renameSync, rmSync } from 'fs';
import { define, manifestFile, outDir } from './vite.target.ts';

export default defineConfig({
  define,
  build: {
    outDir,
    emptyOutDir: false,
    rollupOptions: {
      input: { popup: resolve(import.meta.dirname, 'src/popup/index.html') },
      output: {
        entryFileNames: '[name].js',
        assetFileNames: (info) => info.name === 'index.css' ? 'popup.css' : '[name].[ext]',
      },
    },
  },
  plugins: [
    {
      name: 'flatten-popup-html',
      closeBundle() {
        // Vite mirrors the source path (dist/src/popup/index.html); the manifest wants dist/popup.html.
        renameSync(resolve(import.meta.dirname, outDir, 'src/popup/index.html'), resolve(import.meta.dirname, outDir, 'popup.html'));
        rmSync(resolve(import.meta.dirname, outDir, 'src'), { recursive: true, force: true });
        copyFileSync(resolve(import.meta.dirname, manifestFile), resolve(import.meta.dirname, outDir, 'manifest.json'));
      },
    },
  ],
});
