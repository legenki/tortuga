// Which browser a build is for. `TARGET=firefox npm run build` builds the
// Firefox version into dist-firefox/; anything else builds Chrome into dist/.
export const target: 'chrome' | 'firefox' = process.env.TARGET === 'firefox' ? 'firefox' : 'chrome';
export const outDir = target === 'firefox' ? 'dist-firefox' : 'dist';
export const manifestFile = target === 'firefox' ? 'manifest.firefox.json' : 'manifest.json';
// Compile-time constant, so the other browser's code drops out of the bundle.
export const define = { __TARGET__: JSON.stringify(target) };

/**
 * tldts declares no side effects, so bundlers keep its public-suffix tables
 * (about 190 kB) wherever it is imported, even where only Firefox code uses
 * it and the Chrome build drops that code. It has none: let them go.
 */
export const treeshake = { moduleSideEffects: (id: string) => !/[\\/]node_modules[\\/]tldts/.test(id) };
