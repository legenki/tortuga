import { defineConfig } from 'vite';
import { resolve } from 'path';
import { copyFileSync, renameSync, rmSync } from 'fs';
import { define, manifestFile, outDir } from './vite.target';

export default defineConfig({
  define,
  build: {
    outDir,
    emptyOutDir: false,
    rollupOptions: {
      input: { popup: resolve(__dirname, 'src/popup/index.html') },
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
        renameSync(resolve(__dirname, outDir, 'src/popup/index.html'), resolve(__dirname, outDir, 'popup.html'));
        rmSync(resolve(__dirname, outDir, 'src'), { recursive: true, force: true });
        copyFileSync(resolve(__dirname, manifestFile), resolve(__dirname, outDir, 'manifest.json'));
      },
    },
  ],
});
