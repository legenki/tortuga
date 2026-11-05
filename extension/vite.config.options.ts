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
      input: { options: resolve(__dirname, 'src/options/index.html') },
      output: { entryFileNames: '[name].js', assetFileNames: '[name].[ext]' },
    },
  },
  plugins: [
    {
      name: 'flatten-options-html',
      closeBundle() {
        // Vite mirrors the source path (dist/src/options/index.html); the manifest wants dist/options.html.
        renameSync(resolve(__dirname, outDir, 'src/options/index.html'), resolve(__dirname, outDir, 'options.html'));
        rmSync(resolve(__dirname, outDir, 'src'), { recursive: true, force: true });
      },
    },
  ],
});
