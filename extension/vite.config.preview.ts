import { defineConfig } from 'vite';
import { resolve } from 'path';

// A page that draws the metro diagram in every state, for design work:
//   npm run preview:metro && npx vite preview --config vite.config.preview.ts
export default defineConfig({
  define: { __TARGET__: JSON.stringify('firefox') },
  root: resolve(__dirname, 'dev'),
  publicDir: resolve(__dirname, 'public'),
  build: { outDir: resolve(__dirname, 'dist-preview'), emptyOutDir: true },
  preview: { port: 4174 },
});
