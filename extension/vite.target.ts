// Which browser a build is for. `TARGET=firefox npm run build` builds the
// Firefox version into dist-firefox/; anything else builds Chrome into dist/.
export const target: 'chrome' | 'firefox' = process.env.TARGET === 'firefox' ? 'firefox' : 'chrome';
export const outDir = target === 'firefox' ? 'dist-firefox' : 'dist';
export const manifestFile = target === 'firefox' ? 'manifest.firefox.json' : 'manifest.json';
// Compile-time constant, so the other browser's code drops out of the bundle.
export const define = { __TARGET__: JSON.stringify(target) };
