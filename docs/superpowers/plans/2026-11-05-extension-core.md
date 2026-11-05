# Extension Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Tortuga WebExtension for Chrome and Firefox that turns Tor on and off through `tortuga-helper`: per-site circuits in Firefox, incognito-only routing in Chrome, traffic blocked whenever Tor isn't ready, and a plain popup (switch, status, bridge choice, New circuit, hop list).

**Architecture:** `extension/` copies Nomada's build setup (three Vite configs, `__TARGET__`, tokens, theme). Pure modules — `site.ts`, `state.ts`, `routing.ts`, `view.ts` — hold the rules and are unit-tested. `HelperClient` does request / reply over a native port; `Controller` owns the state and applies route and privacy settings through injected `Deps`, so it is tested with a fake port. `background/index.ts` and `popup/index.ts` only wire browser APIs to these.

**Tech Stack:** TypeScript 5, Vite 5, Vitest 1, `@types/chrome` 0.0.268, `tldts` 7 (public suffix list); `web-ext` 10.8.0 for Firefox lint and runs.

Spec: `docs/superpowers/specs/2026-11-05-tortuga-design.md` (*Extension → Routing*, *Errors*). Helper protocol: `helper/tortuga-helper/src/protocol.rs`.

## Global Constraints

- Plain TypeScript and DOM, no UI framework (Nomada's rule).
- Native host name `org.tortuga.helper`; Firefox add-on id `tortuga@legenki.com`; `PROTOCOL_VERSION` `1`, equal to the helper's.
- Tortuga OFF leaves the browser as if it weren't installed: Chrome's proxy setting cleared, Firefox's `onRequest` answers `undefined`, privacy settings released.
- Whenever Tor is wanted but not ready (connecting, failed, helper gone) traffic goes to `127.0.0.1:1`, never direct.
- Chrome: only `incognito_session_only` scope is touched; regular windows are never routed.
- Firefox minimum 140 (Android 142), Chrome minimum 120.
- The metro diagram, connecting animation, bridge list with mini diagrams, obfs4 / WebTunnel line entry and the settings page are plan 3b. The Downloads tab arrives with the torrents plan.

## File Structure

| File | Responsibility |
|---|---|
| `extension/package.json`, `tsconfig.json`, `vite.target.ts`, `vite.config.{background,theme,popup}.ts`, `vitest.config.ts`, `.gitignore` | Build setup, from Nomada |
| `extension/manifest.json`, `manifest.firefox.json` | Per-browser manifests |
| `extension/src/env.d.ts` | `__TARGET__`, Firefox-only proxy and privacy types |
| `extension/src/styles/tokens.css`, `src/lib/theme.ts`, `src/lib/theme-boot.ts` | Nomada's tokens and light / dark theme |
| `extension/src/lib/protocol.ts` | The helper's messages as TS types |
| `extension/src/lib/site.ts` | URL → site key (registrable domain) |
| `extension/src/lib/state.ts` | `TorState`, `reduce`, `routedPort`, `BLACKHOLE_PORT` |
| `extension/src/lib/messages.ts` | Popup ↔ background messages, stored settings |
| `extension/src/background/helper.ts` | `HelperClient` over a native port |
| `extension/src/background/routing.ts` | Firefox answer, Chrome config |
| `extension/src/background/privacy.ts` | Fingerprinting / WebRTC settings per browser |
| `extension/src/background/controller.ts` | State owner: on / off / new circuit, applies settings |
| `extension/src/background/index.ts` | Wiring: storage, `onRequest`, messages |
| `extension/src/popup/view.ts` | State → what the popup shows |
| `extension/src/popup/index.{html,ts}`, `style.css` | The popup |
| `extension/tests/*.test.ts`, `tests/fake-port.ts` | Unit tests |
| `extension/scripts/register-dev-host.sh` | Development native host (a copy of the helper outside `~/Documents`) |
| `extension/scripts/live-check/{run.sh,check.mjs}` | Automated Firefox live check |

For every task: write the test file, run it and see it fail because the module doesn't exist yet (Vitest 1.6: `Failed to load url … Does the file exist?`), then write the module and see it pass.

---

### Task 1: Scaffold

**Files:**
- Create: `extension/package.json`, `extension/tsconfig.json`, `extension/vite.target.ts`, `extension/vite.config.background.ts`, `extension/vite.config.theme.ts`, `extension/vite.config.popup.ts`, `extension/vitest.config.ts`, `extension/.gitignore`, `extension/manifest.json`, `extension/manifest.firefox.json`, `extension/src/env.d.ts`, `extension/src/styles/tokens.css`, `extension/src/lib/theme.ts`, `extension/src/lib/theme-boot.ts`

- [ ] **Step 1: Write the build files**

`extension/package.json`:

```json
{
  "name": "tortuga-extension",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "npm run typecheck && npm run build:background && npm run build:theme && npm run build:popup",
    "build:background": "vite build --config vite.config.background.ts",
    "build:theme": "vite build --config vite.config.theme.ts",
    "build:popup": "vite build --config vite.config.popup.ts",
    "build:firefox": "TARGET=firefox npm run build",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "lint:firefox": "npx --yes web-ext@10.8.0 lint --source-dir dist-firefox",
    "start:firefox": "npx --yes web-ext@10.8.0 run --source-dir dist-firefox"
  },
  "dependencies": {
    "tldts": "^7.4.19"
  },
  "devDependencies": {
    "@types/chrome": "^0.0.268",
    "typescript": "^5.4.5",
    "vite": "^5.2.12",
    "vitest": "^1.6.0"
  }
}
```

`extension/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "lib": ["ES2022", "DOM"],
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["chrome"]
  },
  "include": ["src", "tests"]
}
```

`extension/vite.target.ts`:

```ts
// Which browser a build is for. `TARGET=firefox npm run build` builds the
// Firefox version into dist-firefox/; anything else builds Chrome into dist/.
export const target: 'chrome' | 'firefox' = process.env.TARGET === 'firefox' ? 'firefox' : 'chrome';
export const outDir = target === 'firefox' ? 'dist-firefox' : 'dist';
export const manifestFile = target === 'firefox' ? 'manifest.firefox.json' : 'manifest.json';
// Compile-time constant, so the other browser's code drops out of the bundle.
export const define = { __TARGET__: JSON.stringify(target) };
```

`extension/vite.config.background.ts`:

```ts
import { defineConfig } from 'vite';
import { resolve } from 'path';
import { define, outDir } from './vite.target';

export default defineConfig({
  define,
  build: {
    outDir,
    // First of the three builds: start from a clean dist so removed files don't ship.
    emptyOutDir: true,
    lib: {
      entry: resolve(__dirname, 'src/background/index.ts'),
      formats: ['es'],
      fileName: () => 'background.js',
    },
    rollupOptions: { external: [] },
  },
});
```

`extension/vite.config.theme.ts`:

```ts
import { defineConfig } from 'vite';
import { resolve } from 'path';
import { define, outDir } from './vite.target';

// theme.js runs as a classic script in the popup's <head>, before the first paint.
export default defineConfig({
  publicDir: false,
  define,
  build: {
    outDir,
    emptyOutDir: false,
    lib: { entry: resolve(__dirname, 'src/lib/theme-boot.ts'), formats: ['iife'], name: 'theme', fileName: () => 'theme.js' },
  },
});
```

`extension/vite.config.popup.ts`:

```ts
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
```

`extension/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  // Tests run the Chrome build; Firefox paths are tested through their parameters.
  define: { __TARGET__: JSON.stringify('chrome') },
  test: { environment: 'node', globals: true },
});
```

`extension/.gitignore`:

```
node_modules/
dist/
dist-firefox/
*.zip
```

- [ ] **Step 2: Write the manifests**

`extension/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "Tortuga — Tor routing",
  "version": "0.1.0",
  "description": "Send incognito windows through Tor with the Tortuga helper. Hides your IP; it is not Tor Browser.",
  "minimum_chrome_version": "120",
  "permissions": ["proxy", "privacy", "storage", "nativeMessaging"],
  "background": { "service_worker": "background.js", "type": "module" },
  "action": { "default_popup": "popup.html" }
}
```

`extension/manifest.firefox.json`:

```json
{
  "manifest_version": 3,
  "name": "Tortuga — Tor routing",
  "version": "0.1.0",
  "description": "Send the browser through Tor with the Tortuga helper, one circuit per site. Hides your IP; it is not Tor Browser.",
  "browser_specific_settings": {
    "gecko": {
      "id": "tortuga@legenki.com",
      "strict_min_version": "140.0",
      "data_collection_permissions": { "required": ["none"] }
    },
    "gecko_android": { "strict_min_version": "142.0" }
  },
  "permissions": ["proxy", "privacy", "storage", "nativeMessaging", "tabs"],
  "host_permissions": ["<all_urls>"],
  "background": { "scripts": ["background.js"], "type": "module" },
  "action": { "default_popup": "popup.html" }
}
```

- [ ] **Step 3: Types, tokens and theme**

`extension/src/env.d.ts`:

```ts
/** Replaced at build time with the browser the build is for (see vite.target.ts). */
declare const __TARGET__: 'chrome' | 'firefox';

// Firefox-only parts of the proxy API, which @types/chrome doesn't describe.
declare namespace chrome.proxy {
  interface FirefoxProxyInfo {
    type: 'direct' | 'http' | 'https' | 'socks' | 'socks4';
    host?: string;
    port?: number;
    /** SOCKS only. */
    username?: string;
    password?: string;
    /** SOCKS only: resolve host names through the proxy. */
    proxyDNS?: boolean;
  }

  interface FirefoxRequestDetails {
    requestId: string;
    url: string;
    tabId: number;
    type: string;
    documentUrl?: string;
    /** Ancestor frames, nearest first; the last one is the top-level page. */
    frameAncestors?: { url: string; frameId: number }[];
  }

  /**
   * undefined: the browser's own setting. A list: proxies to try in order,
   * where a trailing null means "no failover" (fail closed).
   */
  type FirefoxProxyAnswer = FirefoxProxyInfo | (FirefoxProxyInfo | null)[] | null | undefined;

  const onRequest: {
    addListener(
      listener: (details: FirefoxRequestDetails) => FirefoxProxyAnswer | Promise<FirefoxProxyAnswer>,
      filter: { urls: string[] },
    ): void;
  };
}

// Firefox-only privacy settings.
declare namespace chrome.privacy {
  interface Websites {
    resistFingerprinting: chrome.types.ChromeSetting;
  }
  interface Network {
    peerConnectionEnabled: chrome.types.ChromeSetting;
  }
}
```

Copy Nomada's tokens with the header comment changed: `cp ../nomada/src/styles/tokens.css extension/src/styles/tokens.css`, then change the first line to `/* Tortuga design tokens (from Nomada) — shared by the popup and the settings page. */`. Copy `../nomada/src/lib/theme-boot.ts` to `extension/src/lib/theme-boot.ts` unchanged, and `../nomada/src/lib/theme.ts` to `extension/src/lib/theme.ts` with `THEME_KEY` changed from `'nomada-theme'` to `'tortuga-theme'`. (Nomada is checked out next to this repo at `../nomada`.)

- [ ] **Step 4: Install and typecheck**

Run: `cd extension && npm install && npx tsc --noEmit`
Expected: installs without errors; `tsc` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add extension
git commit -m "extension: scaffold from Nomada's build setup"
```

---

### Task 2: Protocol types and site keys

**Files:**
- Create: `extension/src/lib/protocol.ts`, `extension/src/lib/site.ts`
- Test: `extension/tests/site.test.ts`

**Interfaces:**
- Produces: `PROTOCOL_VERSION`, `HOST_NAME`, types `BridgeKind`, `Role`, `Hop`, `Circuit`, `ErrorCode`, `HelperMessage`, `HelperRequest`; `DEFAULT_SITE = 'default'`, `siteOf(url?: string): string`, `topSiteOf(details: chrome.proxy.FirefoxRequestDetails): string`.

- [ ] **Step 1: Write the protocol types**

`extension/src/lib/protocol.ts`:

```ts
// The helper's messages (helper/tortuga-helper/src/protocol.rs), as the
// extension sees them. Keep PROTOCOL_VERSION equal to the helper's.

export const PROTOCOL_VERSION = 1;
/** Native messaging host name, registered by the helper's installer. */
export const HOST_NAME = 'org.tortuga.helper';

export type BridgeKind = 'none' | 'snowflake' | 'obfs4' | 'webtunnel';
export type Role = 'guard' | 'bridge' | 'middle' | 'exit';

export interface Hop {
  role: Role;
  id: string;
  country: string | null;
}

export interface Circuit {
  site: string;
  bridge: Exclude<BridgeKind, 'none'> | null;
  hops: Hop[];
}

export type ErrorCode = 'bad_request' | 'hello_required' | 'protocol_mismatch' | 'tor_failed' | 'not_running';

/** Anything the helper sends: a reply (with id) or an event (without). */
export type HelperMessage =
  | { id?: number; type: 'hello'; payload: { protocol: number; version: string } }
  | { id?: number; type: 'ok' }
  | { id?: number; type: 'tor.status'; payload: { phase: 'bridge' | 'directory' | 'ready'; percent: number; blocked: string | null } }
  | { id?: number; type: 'tor.ready'; payload: { socksPort: number } }
  | { id?: number; type: 'circuit'; payload: Circuit }
  | { id?: number; type: 'error'; payload: { code: ErrorCode; message: string } };

/** What the extension asks the helper. */
export type HelperRequest =
  | { type: 'hello'; payload: { protocol: number } }
  | { type: 'tor.start'; payload: { bridge: { kind: BridgeKind; lines?: string[] } } }
  | { type: 'tor.stop' }
  | { type: 'tor.newCircuit'; payload: { site: string } };
```

- [ ] **Step 2: Write the failing test**

`extension/tests/site.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { DEFAULT_SITE, siteOf, topSiteOf } from '../src/lib/site';

describe('siteOf', () => {
  it('reduces a host to its registrable domain', () => {
    expect(siteOf('https://api.github.com/repos')).toBe('github.com');
    expect(siteOf('https://www.bbc.co.uk/news')).toBe('bbc.co.uk');
  });

  it('keeps private suffixes apart', () => {
    expect(siteOf('https://alice.github.io/')).toBe('alice.github.io');
  });

  it('uses the bare host for IPs and single labels', () => {
    expect(siteOf('http://192.168.1.1/')).toBe('192.168.1.1');
    expect(siteOf('http://[::1]:8080/')).toBe('::1');
    expect(siteOf('http://localhost:3000/')).toBe('localhost');
  });

  it('falls back to the default site', () => {
    expect(siteOf(undefined)).toBe(DEFAULT_SITE);
    expect(siteOf('not a url')).toBe(DEFAULT_SITE);
    expect(siteOf('about:blank')).toBe(DEFAULT_SITE);
  });
});

describe('topSiteOf', () => {
  const base = { requestId: '1', tabId: 1 };

  it('uses the top-level frame for subresources in iframes', () => {
    expect(topSiteOf({
      ...base, type: 'script', url: 'https://cdn.example.net/a.js', documentUrl: 'https://ads.tracker.com/frame',
      frameAncestors: [{ url: 'https://ads.tracker.com/frame', frameId: 5 }, { url: 'https://news.ycombinator.com/', frameId: 0 }],
    })).toBe('ycombinator.com');
  });

  it('uses the request itself for a page load', () => {
    expect(topSiteOf({ ...base, type: 'main_frame', url: 'https://en.wikipedia.org/wiki/Tor' })).toBe('wikipedia.org');
  });

  it('uses the document for a top-level page subresource', () => {
    expect(topSiteOf({ ...base, type: 'image', url: 'https://i.imgur.com/x.png', documentUrl: 'https://www.reddit.com/' })).toBe('reddit.com');
  });
});
```

Run: `cd extension && npx vitest run tests/site.test.ts`
Expected: FAIL — `Failed to load url ../src/lib/site`.

- [ ] **Step 3: Implement**

`extension/src/lib/site.ts`:

```ts
import { getDomain } from 'tldts';

/** The circuit key Chrome uses: it can't tell sites apart (no SOCKS login). */
export const DEFAULT_SITE = 'default';

/**
 * The registrable domain of `url` ("github.com" for "https://api.github.com/x"),
 * or the bare host for IPs and single-label names, or DEFAULT_SITE for URLs
 * without a host.
 */
export function siteOf(url: string | undefined): string {
  if (!url) return DEFAULT_SITE;
  let host: string;
  try {
    host = new URL(url).hostname;
  } catch {
    return DEFAULT_SITE;
  }
  if (!host) return DEFAULT_SITE;
  return getDomain(host, { allowPrivateDomains: true }) ?? host.replace(/^\[|\]$/g, '');
}

/** The site of the top-level page a Firefox request belongs to. */
export function topSiteOf(details: chrome.proxy.FirefoxRequestDetails): string {
  const ancestors = details.frameAncestors;
  if (ancestors && ancestors.length > 0) return siteOf(ancestors[ancestors.length - 1].url);
  if (details.type === 'main_frame') return siteOf(details.url);
  return siteOf(details.documentUrl ?? details.url);
}
```

- [ ] **Step 4: Run the test**

Run: `cd extension && npx vitest run tests/site.test.ts`
Expected: `7 passed`

- [ ] **Step 5: Commit**

```bash
git add extension/src/lib extension/tests
git commit -m "extension: helper protocol types and site keys"
```

---

### Task 3: Tor state

**Files:**
- Create: `extension/src/lib/state.ts`
- Test: `extension/tests/state.test.ts`

**Interfaces:**
- Consumes: `BridgeKind`, `Circuit` (Task 2).
- Produces: `Phase = 'off' | 'connecting' | 'on' | 'failed'`; `TorState { phase, bridge, percent, blocked, socksPort, error, helperMissing, circuits }`; `TorEvent`; `initialState(bridge?)`, `reduce(state, event)`, `BLACKHOLE_PORT = 1`, `routedPort(state): number | null`.

- [ ] **Step 1: Write the failing test**

`extension/tests/state.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { BLACKHOLE_PORT, initialState, reduce, routedPort, type TorState } from '../src/lib/state';
import type { Circuit } from '../src/lib/protocol';

const circuit: Circuit = { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', country: 'DE' }] };

function on(): TorState {
  return reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'ready', socksPort: 9150 });
}

describe('reduce', () => {
  it('off → connecting → on', () => {
    const connecting = reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' });
    expect(connecting).toMatchObject({ phase: 'connecting', bridge: 'snowflake', percent: 0 });
    const progressed = reduce(connecting, { type: 'status', percent: 40, blocked: null });
    expect(progressed.percent).toBe(40);
    expect(reduce(progressed, { type: 'ready', socksPort: 9150 })).toMatchObject({ phase: 'on', socksPort: 9150, percent: 100 });
  });

  it('keeps circuits per site while on', () => {
    expect(reduce(on(), { type: 'circuit', circuit }).circuits['github.com']).toEqual(circuit);
    expect(reduce(initialState(), { type: 'circuit', circuit }).circuits).toEqual({});
  });

  it('a failure while on drops the port', () => {
    const failed = reduce(on(), { type: 'failed', error: 'The helper stopped' });
    expect(failed).toMatchObject({ phase: 'failed', socksPort: null, error: 'The helper stopped' });
  });

  it('a failure while off stays off', () => {
    expect(reduce(initialState(), { type: 'failed', error: 'x' }).phase).toBe('off');
  });

  it('ignores late events from an older start', () => {
    expect(reduce(initialState(), { type: 'ready', socksPort: 9150 }).phase).toBe('off');
  });

  it('turning off keeps the bridge choice', () => {
    expect(reduce(on(), { type: 'turnOff' })).toEqual(initialState('snowflake'));
  });
});

describe('routedPort', () => {
  it('lets traffic go its own way only when off', () => {
    expect(routedPort(initialState())).toBeNull();
  });

  it('uses the SOCKS port when on', () => {
    expect(routedPort(on())).toBe(9150);
  });

  it('blocks while connecting or failed', () => {
    expect(routedPort(reduce(initialState(), { type: 'turnOn', bridge: 'none' }))).toBe(BLACKHOLE_PORT);
    expect(routedPort(reduce(on(), { type: 'failed', error: 'x' }))).toBe(BLACKHOLE_PORT);
  });
});
```

Run: `cd extension && npx vitest run tests/state.test.ts`
Expected: FAIL — `Failed to load url ../src/lib/state`.

- [ ] **Step 2: Implement**

`extension/src/lib/state.ts`:

```ts
import type { BridgeKind, Circuit } from './protocol';

/**
 * off: Tortuga does nothing. connecting / failed: traffic that would go
 * through Tor is blocked. on: traffic goes through the helper's SOCKS port.
 */
export type Phase = 'off' | 'connecting' | 'on' | 'failed';

export interface TorState {
  phase: Phase;
  bridge: BridgeKind;
  percent: number;
  /** Arti's reason when it thinks bootstrap is stuck. */
  blocked: string | null;
  socksPort: number | null;
  error: string | null;
  /** The helper isn't installed (or not registered for this browser). */
  helperMissing: boolean;
  /** Last circuit per site. */
  circuits: Record<string, Circuit>;
}

export type TorEvent =
  | { type: 'turnOn'; bridge: BridgeKind }
  | { type: 'turnOff' }
  | { type: 'status'; percent: number; blocked: string | null }
  | { type: 'ready'; socksPort: number }
  | { type: 'circuit'; circuit: Circuit }
  | { type: 'failed'; error: string; helperMissing?: boolean };

export function initialState(bridge: BridgeKind = 'none'): TorState {
  return { phase: 'off', bridge, percent: 0, blocked: null, socksPort: null, error: null, helperMissing: false, circuits: {} };
}

export function reduce(s: TorState, e: TorEvent): TorState {
  switch (e.type) {
    case 'turnOn':
      return { ...initialState(e.bridge), phase: 'connecting' };
    case 'turnOff':
      return initialState(s.bridge);
    case 'status':
      return s.phase === 'connecting' ? { ...s, percent: e.percent, blocked: e.blocked } : s;
    case 'ready':
      return s.phase === 'connecting' ? { ...s, phase: 'on', percent: 100, blocked: null, socksPort: e.socksPort } : s;
    case 'circuit':
      return s.phase === 'on' ? { ...s, circuits: { ...s.circuits, [e.circuit.site]: e.circuit } } : s;
    case 'failed':
      return {
        ...s,
        phase: s.phase === 'off' ? 'off' : 'failed',
        socksPort: null,
        error: e.error,
        helperMissing: e.helperMissing ?? false,
      };
  }
}

/**
 * Nothing listens on TCP port 1 on desktop systems, so a proxy pointing there
 * makes every request fail at once: the way to block traffic while Tor isn't
 * ready, without letting it out directly.
 */
export const BLACKHOLE_PORT = 1;

/** Where traffic goes: null = the browser's own setting (Tortuga off). */
export function routedPort(s: TorState): number | null {
  if (s.phase === 'off') return null;
  if (s.phase === 'on' && s.socksPort !== null) return s.socksPort;
  return BLACKHOLE_PORT;
}
```

- [ ] **Step 3: Run the test**

Run: `cd extension && npx vitest run tests/state.test.ts`
Expected: `9 passed`

- [ ] **Step 4: Commit**

```bash
git add extension/src/lib/state.ts extension/tests/state.test.ts
git commit -m "extension: Tor state and fail-closed routing rule"
```

---

### Task 4: Helper client

**Files:**
- Create: `extension/src/background/helper.ts`, `extension/tests/fake-port.ts`
- Test: `extension/tests/helper.test.ts`

**Interfaces:**
- Consumes: `HOST_NAME`, `HelperMessage`, `HelperRequest` (Task 2).
- Produces: `PortLike`; `HelperError(code, message)`; `isMissingHost(reason): boolean`; `HelperClient(port, onEvent, onGone, lastError?)` with `request(req): Promise<HelperMessage>` and `close()`; `connectHelper(onEvent, onGone): HelperClient`. Test helpers `FakePort` (`sent`, `disconnected`, `emit`, `die`, `idOf`) and `flush()`.

- [ ] **Step 1: Write the fake port and the failing test**

`extension/tests/fake-port.ts`:

```ts
import type { HelperMessage } from '../src/lib/protocol';
import type { PortLike } from '../src/background/helper';

/** An in-memory native port: records what the extension sends, lets tests answer. */
export class FakePort implements PortLike {
  sent: Record<string, unknown>[] = [];
  disconnected = false;
  private messageFns: ((m: HelperMessage) => void)[] = [];
  private disconnectFns: (() => void)[] = [];

  onMessage = { addListener: (fn: (m: HelperMessage) => void) => void this.messageFns.push(fn) };
  onDisconnect = { addListener: (fn: () => void) => void this.disconnectFns.push(fn) };

  postMessage(message: unknown): void {
    this.sent.push(message as Record<string, unknown>);
  }

  disconnect(): void {
    this.disconnected = true;
  }

  /** The helper sends `m`. */
  emit(m: HelperMessage): void {
    for (const fn of this.messageFns) fn(m);
  }

  /** The helper process goes away. */
  die(): void {
    for (const fn of this.disconnectFns) fn();
  }

  /** The id of the last request of `type`. */
  idOf(type: string): number {
    const req = [...this.sent].reverse().find(m => m.type === type);
    if (!req) throw new Error(`no ${type} sent`);
    return req.id as number;
  }
}

/** Let pending promise callbacks run. */
export const flush = () => new Promise(r => setTimeout(r, 0));
```

`extension/tests/helper.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { HelperClient, HelperError, isMissingHost } from '../src/background/helper';
import { FakePort } from './fake-port';

describe('HelperClient', () => {
  it('matches replies to requests by id', async () => {
    const port = new FakePort();
    const client = new HelperClient(port, () => {}, () => {});
    const hello = client.request({ type: 'hello', payload: { protocol: 1 } });
    expect(port.sent[0]).toEqual({ id: 1, type: 'hello', payload: { protocol: 1 } });
    port.emit({ id: 1, type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await expect(hello).resolves.toMatchObject({ type: 'hello' });
  });

  it('rejects on an error reply', async () => {
    const port = new FakePort();
    const client = new HelperClient(port, () => {}, () => {});
    const start = client.request({ type: 'tor.start', payload: { bridge: { kind: 'none' } } });
    port.emit({ id: 1, type: 'error', payload: { code: 'tor_failed', message: 'no network' } });
    await expect(start).rejects.toEqual(new HelperError('tor_failed', 'no network'));
  });

  it('passes messages without an id to onEvent', () => {
    const port = new FakePort();
    const events: string[] = [];
    new HelperClient(port, m => events.push(m.type), () => {});
    port.emit({ type: 'tor.status', payload: { phase: 'directory', percent: 30, blocked: null } });
    expect(events).toEqual(['tor.status']);
  });

  it('on disconnect rejects pending requests and reports why', async () => {
    const port = new FakePort();
    const gone: string[] = [];
    const client = new HelperClient(port, () => {}, r => gone.push(r), () => 'Specified native messaging host not found.');
    const hello = client.request({ type: 'hello', payload: { protocol: 1 } });
    port.die();
    await expect(hello).rejects.toThrow('Specified native messaging host not found.');
    expect(gone).toEqual(['Specified native messaging host not found.']);
  });

  it('close() does not report the helper as gone', () => {
    const port = new FakePort();
    const gone: string[] = [];
    const client = new HelperClient(port, () => {}, r => gone.push(r));
    client.close();
    port.die();
    expect(port.disconnected).toBe(true);
    expect(gone).toEqual([]);
  });
});

describe('isMissingHost', () => {
  it('recognises both browsers', () => {
    expect(isMissingHost('Specified native messaging host not found.')).toBe(true);
    expect(isMissingHost('No such native application org.tortuga.helper')).toBe(true);
    expect(isMissingHost('Native host has exited.')).toBe(false);
  });
});
```

Run: `cd extension && npx vitest run tests/helper.test.ts`
Expected: FAIL — `Failed to load url ../src/background/helper`.

- [ ] **Step 2: Implement**

`extension/src/background/helper.ts`:

```ts
import { HOST_NAME, type HelperMessage, type HelperRequest } from '../lib/protocol';

/** The part of chrome.runtime.Port the client uses (a fake in tests). */
export interface PortLike {
  postMessage(message: unknown): void;
  onMessage: { addListener(fn: (message: HelperMessage) => void): void };
  onDisconnect: { addListener(fn: () => void): void };
  disconnect(): void;
}

export class HelperError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

/** Chrome: "Specified native messaging host not found." Firefox: "No such native application …". */
export function isMissingHost(reason: string): boolean {
  return /native messaging host not found|no such native application/i.test(reason);
}

type Pending = { resolve: (m: HelperMessage) => void; reject: (e: Error) => void };

/**
 * Request / reply over a native port: each request gets an id, its reply
 * resolves the promise (an `error` reply rejects it), messages without an id
 * are events.
 */
export class HelperClient {
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private closed = false;

  constructor(
    private readonly port: PortLike,
    onEvent: (m: HelperMessage) => void,
    onGone: (reason: string) => void,
    lastError: () => string | undefined = () => undefined,
  ) {
    port.onMessage.addListener(m => {
      const waiting = m.id === undefined ? undefined : this.pending.get(m.id);
      if (!waiting) return onEvent(m);
      this.pending.delete(m.id!);
      if (m.type === 'error') waiting.reject(new HelperError(m.payload.code, m.payload.message));
      else waiting.resolve(m);
    });
    port.onDisconnect.addListener(() => {
      const reason = lastError() ?? 'The helper stopped';
      this.fail(reason);
      if (!this.closed) onGone(reason);
      this.closed = true;
    });
  }

  request(req: HelperRequest): Promise<HelperMessage> {
    if (this.closed) return Promise.reject(new HelperError('closed', 'The helper is not connected'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.port.postMessage({ id, ...req });
    });
  }

  /** Disconnect on purpose: no onGone call. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.fail('Disconnected');
    this.port.disconnect();
  }

  private fail(reason: string): void {
    for (const p of this.pending.values()) p.reject(new HelperError('closed', reason));
    this.pending.clear();
  }
}

export function connectHelper(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient {
  const port = chrome.runtime.connectNative(HOST_NAME) as unknown as PortLike;
  return new HelperClient(port, onEvent, onGone, () => chrome.runtime.lastError?.message);
}
```

- [ ] **Step 3: Run the test**

Run: `cd extension && npx vitest run tests/helper.test.ts`
Expected: `6 passed`

- [ ] **Step 4: Commit**

```bash
git add extension/src/background/helper.ts extension/tests
git commit -m "extension: request / reply client for the helper"
```

---

### Task 5: Routing and privacy settings

**Files:**
- Create: `extension/src/background/routing.ts`, `extension/src/background/privacy.ts`
- Test: `extension/tests/routing.test.ts`

**Interfaces:**
- Consumes: `topSiteOf` (Task 2).
- Produces: `firefoxAnswer(port: number | null, details): FirefoxProxyAnswer`; `chromeConfig(port): chrome.proxy.ProxyConfig`; `applyChromeRoute(port: number | null): Promise<void>`; `applyPrivacy(on: boolean): Promise<void>`.

- [ ] **Step 1: Write the failing test**

`extension/tests/routing.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { chromeConfig, firefoxAnswer } from '../src/background/routing';

describe('firefoxAnswer', () => {
  const page = { requestId: '1', tabId: 1, type: 'main_frame', url: 'https://www.torproject.org/' };

  it('leaves requests alone when off', () => {
    expect(firefoxAnswer(null, page)).toBeUndefined();
  });

  it('sends the site as SOCKS login with no failover', () => {
    expect(firefoxAnswer(9150, page)).toEqual([
      { type: 'socks', host: '127.0.0.1', port: 9150, proxyDNS: true, username: 'torproject.org', password: 'x' },
      null,
    ]);
  });
});

describe('chromeConfig', () => {
  it('is one SOCKS5 server', () => {
    expect(chromeConfig(9150)).toEqual({ mode: 'fixed_servers', rules: { singleProxy: { scheme: 'socks5', host: '127.0.0.1', port: 9150 } } });
  });
});
```

Run: `cd extension && npx vitest run tests/routing.test.ts`
Expected: FAIL — `Failed to load url ../src/background/routing`.

- [ ] **Step 2: Implement**

`extension/src/background/routing.ts`:

```ts
import { topSiteOf } from '../lib/site';

const LOCALHOST = '127.0.0.1';

/**
 * Firefox: the answer for one request. No port: the browser's own setting.
 * Otherwise the helper's SOCKS port with the site as login, so each site gets
 * its own circuits, and no failover, so nothing goes out directly.
 */
export function firefoxAnswer(port: number | null, details: chrome.proxy.FirefoxRequestDetails): chrome.proxy.FirefoxProxyAnswer {
  if (port === null) return undefined;
  return [{ type: 'socks', host: LOCALHOST, port, proxyDNS: true, username: topSiteOf(details), password: 'x' }, null];
}

/** Chrome: one SOCKS5 server for the incognito session (Chrome can't send a SOCKS login). */
export function chromeConfig(port: number): chrome.proxy.ProxyConfig {
  return { mode: 'fixed_servers', rules: { singleProxy: { scheme: 'socks5', host: LOCALHOST, port } } };
}

/** Chrome: route incognito windows through `port`, or release the setting. */
export async function applyChromeRoute(port: number | null): Promise<void> {
  if (port === null) await chrome.proxy.settings.clear({ scope: 'incognito_session_only' });
  else await chrome.proxy.settings.set({ value: chromeConfig(port), scope: 'incognito_session_only' });
}
```

`extension/src/background/privacy.ts` (browser-only, covered by the live check in Task 8):

```ts
// Browser settings that go with Tor mode, set while it's on and released when
// it's off. A setting another extension or a policy controls is left alone.

type Setting = chrome.types.ChromeSetting;
type Scope = 'regular' | 'incognito_session_only';

async function set(setting: Setting | undefined, value: unknown, scope?: Scope): Promise<void> {
  try {
    await setting?.set(scope ? { value, scope } : { value });
  } catch (e) {
    console.warn('Tortuga: setting not applied', e);
  }
}

async function clear(setting: Setting | undefined, scope?: Scope): Promise<void> {
  try {
    await setting?.clear(scope ? { scope } : {});
  } catch (e) {
    console.warn('Tortuga: setting not released', e);
  }
}

export async function applyPrivacy(on: boolean): Promise<void> {
  if (__TARGET__ === 'firefox') {
    const fingerprint = chrome.privacy.websites.resistFingerprinting;
    const webrtc = chrome.privacy.network.peerConnectionEnabled;
    if (on) {
      await set(fingerprint, true);
      await set(webrtc, false);
    } else {
      await clear(fingerprint);
      await clear(webrtc);
    }
  } else {
    // Only the incognito session goes through Tor, so only it gets the WebRTC rule.
    const webrtc = chrome.privacy.network.webRTCIPHandlingPolicy;
    if (on) await set(webrtc, 'disable_non_proxied_udp', 'incognito_session_only');
    else await clear(webrtc, 'incognito_session_only');
  }
}
```

- [ ] **Step 3: Run the test and typecheck**

Run: `cd extension && npx vitest run tests/routing.test.ts && npx tsc --noEmit`
Expected: `3 passed`; `tsc` prints nothing.

- [ ] **Step 4: Commit**

```bash
git add extension/src/background extension/tests/routing.test.ts
git commit -m "extension: per-browser routing and privacy settings"
```

---

### Task 6: Controller

**Files:**
- Create: `extension/src/lib/messages.ts`, `extension/src/background/controller.ts`
- Test: `extension/tests/controller.test.ts`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces: `BgMessage` (`GET_STATE`, `TOR_ON { bridge }`, `TOR_OFF`, `NEW_CIRCUIT { site }`), `BgBroadcast` (`STATE { state }`), `Stored { enabled, bridge }`, `STORAGE_KEY = 'tortuga'`; `Deps { connect, applyRoute, applyPrivacy, save, broadcast, incognitoAllowed }`; `Controller(deps)` with `current`, `port`, `turnOn(bridge)`, `turnOff()`, `newCircuit(site)` (each resolves to the new `TorState`); messages `INCOGNITO_NEEDED`, `HELPER_MISSING`.

- [ ] **Step 1: Write the messages module**

`extension/src/lib/messages.ts`:

```ts
import type { BridgeKind } from './protocol';
import type { TorState } from './state';

/** Popup → background. Each is answered with the current TorState. */
export type BgMessage =
  | { type: 'GET_STATE' }
  | { type: 'TOR_ON'; bridge: BridgeKind }
  | { type: 'TOR_OFF' }
  | { type: 'NEW_CIRCUIT'; site: string };

/** Background → popup, after every change. */
export type BgBroadcast = { type: 'STATE'; state: TorState };

/** What survives the background being restarted. */
export interface Stored {
  enabled: boolean;
  bridge: BridgeKind;
}

export const STORAGE_KEY = 'tortuga';
```

- [ ] **Step 2: Write the failing test**

`extension/tests/controller.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { Controller, HELPER_MISSING, INCOGNITO_NEEDED, type Deps } from '../src/background/controller';
import { HelperClient } from '../src/background/helper';
import type { Stored } from '../src/lib/messages';
import { BLACKHOLE_PORT, type TorState } from '../src/lib/state';
import { FakePort, flush } from './fake-port';

function setup(opts: { incognito?: boolean; lastError?: string } = {}) {
  const ports: FakePort[] = [];
  const routes: (number | null)[] = [];
  const privacy: boolean[] = [];
  const saved: Stored[] = [];
  const states: TorState[] = [];
  const deps: Deps = {
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => opts.lastError);
    },
    applyRoute: async p => void routes.push(p),
    applyPrivacy: async on => void privacy.push(on),
    save: async s => void saved.push(s),
    broadcast: s => void states.push(s),
    incognitoAllowed: async () => opts.incognito ?? true,
  };
  return { c: new Controller(deps), ports, routes, privacy, saved, states };
}

/** Answer hello and tor.start the way a healthy helper does. */
async function boot(port: FakePort, socksPort = 9150) {
  await flush();
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
  await flush();
  port.emit({ id: port.idOf('tor.start'), type: 'tor.ready', payload: { socksPort } });
  await flush();
}

describe('Controller', () => {
  it('blocks traffic while connecting, then routes through the SOCKS port', async () => {
    const { c, ports, routes, privacy, saved } = setup();
    await c.turnOn('snowflake');
    expect(routes).toEqual([BLACKHOLE_PORT]);
    expect(privacy).toEqual([true]);
    expect(saved).toEqual([{ enabled: true, bridge: 'snowflake' }]);
    await boot(ports[0]);
    expect(ports[0].sent[1]).toMatchObject({ type: 'tor.start', payload: { bridge: { kind: 'snowflake' } } });
    expect(c.current.phase).toBe('on');
    expect(routes).toEqual([BLACKHOLE_PORT, 9150]);
  });

  it('turning off releases the route and privacy settings and the helper', async () => {
    const { c, ports, routes, privacy, saved } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    await c.turnOff();
    expect(routes.at(-1)).toBeNull();
    expect(privacy.at(-1)).toBe(false);
    expect(saved.at(-1)).toEqual({ enabled: false, bridge: 'none' });
    expect(ports[0].disconnected).toBe(true);
  });

  it('keeps traffic blocked when the helper dies', async () => {
    const { c, ports, routes } = setup({ lastError: 'Native host has exited.' });
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].die();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', error: 'Native host has exited.', helperMissing: false });
    expect(routes.at(-1)).toBe(BLACKHOLE_PORT);
  });

  it('reports a missing helper', async () => {
    const { c, ports } = setup({ lastError: 'Specified native messaging host not found.' });
    await c.turnOn('none');
    ports[0].die();
    await flush();
    await flush();
    expect(c.current).toMatchObject({ phase: 'failed', helperMissing: true, error: HELPER_MISSING });
  });

  it('asks to update an older helper', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'error', payload: { code: 'protocol_mismatch', message: 'helper speaks protocol 2, extension 1' } });
    await flush();
    await flush();
    expect(c.current.phase).toBe('failed');
    expect(c.current.error).toMatch(/^Update the Tortuga helper/);
  });

  it('Chrome without incognito access fails before starting the helper', async () => {
    const { c, ports } = setup({ incognito: false });
    await c.turnOn('none');
    expect(ports).toEqual([]);
    expect(c.current).toMatchObject({ phase: 'failed', error: INCOGNITO_NEEDED });
  });

  it('stores circuits and asks for new ones', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await boot(ports[0]);
    ports[0].emit({ type: 'circuit', payload: { site: 'github.com', bridge: null, hops: [{ role: 'guard', id: 'g', country: 'DE' }] } });
    await flush();
    expect(c.current.circuits['github.com'].hops[0].id).toBe('g');
    const renewed = c.newCircuit('github.com');
    await flush();
    ports[0].emit({ id: ports[0].idOf('tor.newCircuit'), type: 'ok' });
    await renewed;
    expect(ports[0].sent.at(-1)).toMatchObject({ type: 'tor.newCircuit', payload: { site: 'github.com' } });
  });

  it('a reply to an older start does not turn Tor on', async () => {
    const { c, ports } = setup();
    await c.turnOn('none');
    await flush();
    await c.turnOff();
    ports[0].emit({ id: ports[0].idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.1.0' } });
    await flush();
    expect(c.current.phase).toBe('off');
  });
});
```

Run: `cd extension && npx vitest run tests/controller.test.ts`
Expected: FAIL — `Failed to load url ../src/background/controller`.

- [ ] **Step 3: Implement**

`extension/src/background/controller.ts`:

```ts
import type { BridgeKind, HelperMessage } from '../lib/protocol';
import { PROTOCOL_VERSION } from '../lib/protocol';
import type { Stored } from '../lib/messages';
import { initialState, reduce, routedPort, type TorEvent, type TorState } from '../lib/state';
import { HelperError, isMissingHost, type HelperClient } from './helper';

/** Everything the controller does to the outside world (fakes in tests). */
export interface Deps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
  applyRoute(port: number | null): Promise<void>;
  applyPrivacy(on: boolean): Promise<void>;
  save(stored: Stored): Promise<void>;
  broadcast(state: TorState): void;
  /** Chrome: may Tortuga touch incognito windows? Firefox: always true. */
  incognitoAllowed(): Promise<boolean>;
}

export const INCOGNITO_NEEDED = 'Allow Tortuga in Incognito (Manage extension → Allow in Incognito), then try again.';
export const HELPER_MISSING = 'The Tortuga helper is not installed.';

/**
 * Owns the Tor state. Every change goes through `commit`, which applies the
 * route and privacy settings only when they change. Changes are serialized.
 */
export class Controller {
  private state: TorState = initialState();
  private helper: HelperClient | null = null;
  private appliedPort: number | null = null;
  private privacyOn = false;
  private queue: Promise<unknown> = Promise.resolve();
  /** Bumped on every turn on / off, so a stale start can't overwrite a newer one. */
  private generation = 0;

  constructor(private readonly deps: Deps) {}

  get current(): TorState {
    return this.state;
  }

  /** The SOCKS port traffic goes to right now (null: browser's own setting). */
  get port(): number | null {
    return routedPort(this.state);
  }

  turnOn(bridge: BridgeKind): Promise<TorState> {
    return this.serial(async () => {
      const gen = ++this.generation;
      this.helper?.close();
      this.helper = null;
      await this.commit({ type: 'turnOn', bridge });
      await this.deps.save({ enabled: true, bridge });
      if (!(await this.deps.incognitoAllowed())) {
        await this.commit({ type: 'failed', error: INCOGNITO_NEEDED });
        return this.state;
      }
      const helper = this.deps.connect(
        m => void this.serial(() => this.onEvent(m)),
        reason => void this.serial(() => this.onGone(helper, reason)),
      );
      this.helper = helper;
      void this.start(helper, bridge, gen);
      return this.state;
    });
  }

  turnOff(): Promise<TorState> {
    return this.serial(async () => {
      this.generation++;
      this.helper?.close();
      this.helper = null;
      await this.commit({ type: 'turnOff' });
      await this.deps.save({ enabled: false, bridge: this.state.bridge });
      return this.state;
    });
  }

  newCircuit(site: string): Promise<TorState> {
    return this.serial(async () => {
      if (this.state.phase === 'on' && this.helper) {
        await this.helper.request({ type: 'tor.newCircuit', payload: { site } }).catch(() => undefined);
      }
      return this.state;
    });
  }

  private async start(helper: HelperClient, bridge: BridgeKind, gen: number): Promise<void> {
    try {
      await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
      const reply = await helper.request({ type: 'tor.start', payload: { bridge: { kind: bridge } } });
      if (reply.type !== 'tor.ready') throw new Error(`unexpected reply ${reply.type}`);
      await this.serial(async () => {
        if (gen === this.generation) await this.commit({ type: 'ready', socksPort: reply.payload.socksPort });
      });
    } catch (e) {
      await this.serial(async () => {
        if (gen !== this.generation) return;
        const err = e as Error;
        const missing = isMissingHost(err.message);
        const message = missing
          ? HELPER_MISSING
          : err instanceof HelperError && err.code === 'protocol_mismatch'
            ? `Update the Tortuga helper: ${err.message}`
            : err.message;
        await this.commit({ type: 'failed', error: message, helperMissing: missing });
      });
    }
  }

  private async onEvent(m: HelperMessage): Promise<void> {
    if (m.type === 'tor.status') await this.commit({ type: 'status', percent: m.payload.percent, blocked: m.payload.blocked });
    else if (m.type === 'circuit') await this.commit({ type: 'circuit', circuit: m.payload });
  }

  private async onGone(helper: HelperClient, reason: string): Promise<void> {
    if (helper !== this.helper) return;
    this.helper = null;
    const missing = isMissingHost(reason);
    await this.commit({ type: 'failed', error: missing ? HELPER_MISSING : reason, helperMissing: missing });
  }

  private async commit(e: TorEvent): Promise<void> {
    this.state = reduce(this.state, e);
    const port = routedPort(this.state);
    if (port !== this.appliedPort) {
      await this.deps.applyRoute(port);
      this.appliedPort = port;
    }
    const privacy = this.state.phase !== 'off';
    if (privacy !== this.privacyOn) {
      await this.deps.applyPrivacy(privacy);
      this.privacyOn = privacy;
    }
    this.deps.broadcast(this.state);
  }

  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch(() => undefined);
    return next;
  }
}
```

- [ ] **Step 4: Run the test**

Run: `cd extension && npx vitest run tests/controller.test.ts`
Expected: `8 passed`

- [ ] **Step 5: Commit**

```bash
git add extension/src extension/tests/controller.test.ts
git commit -m "extension: controller for Tor on / off and failures"
```

---

### Task 7: Background wiring, popup, builds

**Files:**
- Create: `extension/src/background/index.ts`, `extension/src/popup/view.ts`, `extension/src/popup/index.ts`, `extension/src/popup/index.html`, `extension/src/popup/style.css`
- Test: `extension/tests/view.test.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: `viewFor(state, site): View`; the built extensions in `dist/` and `dist-firefox/`.

- [ ] **Step 1: Write the failing view test**

`extension/tests/view.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { viewFor } from '../src/popup/view';
import { initialState, reduce } from '../src/lib/state';

describe('viewFor', () => {
  it('shows progress while connecting', () => {
    const s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'snowflake' }), { type: 'status', percent: 40, blocked: null });
    expect(viewFor(s, 'default')).toMatchObject({ torSelected: true, tone: 'busy', status: 'Connecting via Snowflake… 40%' });
  });

  it('lists the hops of the site when on', () => {
    let s = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 9150 });
    s = reduce(s, { type: 'circuit', circuit: { site: 'default', bridge: null, hops: [{ role: 'exit', id: 'abcdefghij', country: null }] } });
    expect(viewFor(s, 'default')).toMatchObject({ tone: 'on', canNewCircuit: true, hops: ['Exit · — · abcdefgh'] });
  });

  it('offers Restart after a failure but not for a missing helper', () => {
    const on = reduce(reduce(initialState(), { type: 'turnOn', bridge: 'none' }), { type: 'ready', socksPort: 1 });
    expect(viewFor(reduce(on, { type: 'failed', error: 'gone' }), 'default')).toMatchObject({ tone: 'alert', showRestart: true });
    expect(viewFor(reduce(on, { type: 'failed', error: 'x', helperMissing: true }), 'default')).toMatchObject({ status: 'Helper not installed', showRestart: false });
  });
});
```

Run: `cd extension && npx vitest run tests/view.test.ts`
Expected: FAIL — `Failed to load url ../src/popup/view`.

- [ ] **Step 2: Implement the view**

`extension/src/popup/view.ts`:

```ts
import type { Circuit } from '../lib/protocol';
import type { TorState } from '../lib/state';

/** What the popup shows for a state: pure, so it can be tested. */
export interface View {
  /** Tor side of the switch is selected. */
  torSelected: boolean;
  /** data-state on the status line: colours the dot. */
  tone: 'off' | 'busy' | 'on' | 'alert';
  status: string;
  /** A longer explanation under the status, or null. */
  note: string | null;
  showRestart: boolean;
  canNewCircuit: boolean;
  /** One line per hop of the active tab's circuit. */
  hops: string[];
}

const BRIDGE_NAMES = { none: 'no bridge', snowflake: 'Snowflake', obfs4: 'obfs4', webtunnel: 'WebTunnel' } as const;

function hopLine(h: Circuit['hops'][number]): string {
  const role = { guard: 'Guard', bridge: 'Bridge', middle: 'Middle', exit: 'Exit' }[h.role];
  return `${role} · ${h.country ?? '—'} · ${h.id.slice(0, 8)}`;
}

export function viewFor(s: TorState, site: string): View {
  const base: View = { torSelected: s.phase !== 'off', tone: 'off', status: '', note: null, showRestart: false, canNewCircuit: false, hops: [] };
  switch (s.phase) {
    case 'off':
      return { ...base, status: 'Direct — Tortuga is off', note: s.error };
    case 'connecting':
      return {
        ...base,
        tone: 'busy',
        status: `Connecting via ${BRIDGE_NAMES[s.bridge]}… ${s.percent}%`,
        note: s.blocked ?? 'Traffic waits until Tor is ready.',
      };
    case 'on': {
      const circuit = s.circuits[site];
      return {
        ...base,
        tone: 'on',
        status: `Tor on via ${BRIDGE_NAMES[s.bridge]}`,
        note: __TARGET__ === 'chrome' ? 'Only incognito windows use Tor in Chrome, all through one circuit.' : null,
        canNewCircuit: true,
        hops: circuit ? circuit.hops.map(hopLine) : [],
      };
    }
    case 'failed':
      return {
        ...base,
        tone: 'alert',
        status: s.helperMissing ? 'Helper not installed' : 'Tor stopped — traffic is blocked',
        note: s.error,
        showRestart: !s.helperMissing,
      };
  }
}
```

Run: `cd extension && npx vitest run tests/view.test.ts`
Expected: `3 passed`

- [ ] **Step 3: Background wiring**

`extension/src/background/index.ts`:

```ts
import { STORAGE_KEY, type BgBroadcast, type BgMessage, type Stored } from '../lib/messages';
import type { TorState } from '../lib/state';
import { Controller } from './controller';
import { connectHelper } from './helper';
import { applyPrivacy } from './privacy';
import { applyChromeRoute, firefoxAnswer } from './routing';

const controller = new Controller({
  connect: connectHelper,
  // Firefox asks proxy.onRequest about each request (below); Chrome has one setting.
  applyRoute: port => (__TARGET__ === 'firefox' ? Promise.resolve() : applyChromeRoute(port)),
  applyPrivacy,
  save: stored => chrome.storage.local.set({ [STORAGE_KEY]: stored }),
  broadcast: (state: TorState) => {
    const msg: BgBroadcast = { type: 'STATE', state };
    chrome.runtime.sendMessage(msg).catch(() => { /* no popup open */ });
  },
  incognitoAllowed: () => (__TARGET__ === 'firefox' ? Promise.resolve(true) : chrome.extension.isAllowedIncognitoAccess()),
});

// If Tortuga was on when the background last stopped, start again. Until Tor
// is ready, routedPort() blocks traffic instead of letting it out directly.
const restored = chrome.storage.local.get(STORAGE_KEY).then(async r => {
  const stored = r[STORAGE_KEY] as Stored | undefined;
  if (stored?.enabled) await controller.turnOn(stored.bridge);
});

if (__TARGET__ === 'firefox') {
  // A persistent listener: Firefox wakes the background for it. Requests wait
  // for the stored state, so none slips out before Tortuga knows it is on.
  chrome.proxy.onRequest.addListener(async details => {
    await restored;
    return firefoxAnswer(controller.port, details);
  }, { urls: ['<all_urls>'] });
}

chrome.runtime.onMessage.addListener((msg: BgMessage, _sender, sendResponse) => {
  const reply = (p: Promise<TorState>) => {
    p.then(sendResponse, () => sendResponse(controller.current));
    return true;
  };
  switch (msg.type) {
    case 'GET_STATE':
      return reply(restored.then(() => controller.current));
    case 'TOR_ON':
      return reply(controller.turnOn(msg.bridge));
    case 'TOR_OFF':
      return reply(controller.turnOff());
    case 'NEW_CIRCUIT':
      return reply(controller.newCircuit(msg.site));
  }
  return false;
});
```

- [ ] **Step 4: Popup**

`extension/src/popup/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Tortuga</title>
  <script src="/theme.js"></script>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="bar">
    <div class="brand">Tortuga</div>
    <div class="conn" role="radiogroup" aria-label="Connection">
      <label><input type="radio" name="conn" id="connDirect" value="direct"><span>Direct</span></label>
      <label><input type="radio" name="conn" id="connTor" value="tor"><span>Tor</span></label>
    </div>
  </header>

  <main>
    <div class="status" id="status" data-state="off" aria-live="polite">
      <span class="status-dot"></span><span id="statusText">…</span>
    </div>
    <p class="note" id="note" hidden></p>
    <ol class="hops" id="hops" hidden></ol>

    <div class="row">
      <label class="field">Bridge
        <select id="bridge">
          <option value="none">No bridge</option>
          <option value="snowflake">Snowflake</option>
        </select>
      </label>
      <button class="btn" id="newCircuit" type="button" disabled>New circuit</button>
    </div>
    <button class="btn btn-primary" id="restart" type="button" hidden>Restart</button>
  </main>

  <script type="module" src="index.ts"></script>
</body>
</html>
```

`extension/src/popup/index.ts`:

```ts
import type { BgBroadcast, BgMessage } from '../lib/messages';
import type { BridgeKind } from '../lib/protocol';
import { DEFAULT_SITE, siteOf } from '../lib/site';
import type { TorState } from '../lib/state';
import { viewFor } from './view';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const connDirect = $<HTMLInputElement>('connDirect');
const connTor = $<HTMLInputElement>('connTor');
const bridge = $<HTMLSelectElement>('bridge');
const status = $('status');
const statusText = $('statusText');
const note = $('note');
const hops = $('hops');
const restart = $<HTMLButtonElement>('restart');
const newCircuit = $<HTMLButtonElement>('newCircuit');

let site = DEFAULT_SITE;
let state: TorState | null = null;

function send(msg: BgMessage): Promise<TorState> {
  return chrome.runtime.sendMessage(msg);
}

function render(s: TorState): void {
  state = s;
  const v = viewFor(s, site);
  connTor.checked = v.torSelected;
  connDirect.checked = !v.torSelected;
  bridge.value = s.bridge;
  status.dataset.state = v.tone;
  statusText.textContent = v.status;
  note.textContent = v.note ?? '';
  note.hidden = !v.note;
  restart.hidden = !v.showRestart;
  newCircuit.disabled = !v.canNewCircuit;
  hops.replaceChildren(...v.hops.map(line => Object.assign(document.createElement('li'), { textContent: line })));
  hops.hidden = v.hops.length === 0;
}

const turnOn = () => send({ type: 'TOR_ON', bridge: bridge.value as BridgeKind }).then(render);

connTor.addEventListener('change', turnOn);
connDirect.addEventListener('change', () => send({ type: 'TOR_OFF' }).then(render));
restart.addEventListener('click', turnOn);
bridge.addEventListener('change', () => { if (state && state.phase !== 'off') void turnOn(); });
newCircuit.addEventListener('click', () => send({ type: 'NEW_CIRCUIT', site }).then(render));

chrome.runtime.onMessage.addListener((msg: BgBroadcast) => {
  if (msg.type === 'STATE') render(msg.state);
});

async function init(): Promise<void> {
  if (__TARGET__ === 'firefox') {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    site = siteOf(tab?.url);
  }
  render(await send({ type: 'GET_STATE' }));
}

void init();
```

`extension/src/popup/style.css`:

```css
/* Tortuga popup — Nomada's look; the metro diagram arrives in plan 3b. */

@import '../styles/tokens.css';

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body {
  width: 340px;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.45 var(--font);
  -webkit-font-smoothing: antialiased;
}

button, select { font: inherit; color: inherit; }
:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }

.bar { display: flex; align-items: center; justify-content: space-between; padding: 14px 16px 10px; }
.brand { font-weight: 700; font-size: 15px; }

.conn { display: inline-grid; grid-auto-flow: column; padding: 3px; border-radius: 999px; background: var(--surface-2); font-size: 12px; font-weight: 600; }
.conn label { position: relative; cursor: pointer; }
.conn input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: inherit; }
.conn span { display: block; padding: 4px 12px; border-radius: 999px; color: var(--text-3); text-align: center; transition: background 0.15s, color 0.15s; }
.conn input:checked + span { background: var(--surface); color: var(--text); box-shadow: 0 0 0 1px var(--line); }
.conn input#connTor:checked + span { color: var(--accent); }
.conn input:focus-visible + span { outline: 2px solid var(--focus); outline-offset: 1px; }

main { display: grid; gap: 10px; padding: 0 16px 16px; }

.status { display: flex; align-items: center; gap: 8px; font-weight: 600; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--text-3); }
.status[data-state="busy"] .status-dot { background: var(--caution); }
.status[data-state="on"] .status-dot { background: var(--accent); }
.status[data-state="alert"] { color: var(--warn); }
.status[data-state="alert"] .status-dot { background: var(--warn); }

.note { color: var(--text-2); font-size: 12px; }

.hops { list-style: none; display: grid; gap: 4px; padding: 10px; border: 1px solid var(--line); border-radius: 12px; background: var(--surface); font: 12px/1.4 var(--mono); }

.row { display: flex; align-items: end; justify-content: space-between; gap: 10px; }
.field { display: grid; gap: 4px; font-size: 11px; color: var(--text-3); }
.field select { padding: 5px 8px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); }

.btn { padding: 6px 12px; border: 1px solid var(--line); border-radius: 999px; background: var(--surface); cursor: pointer; font-weight: 600; font-size: 12px; }
.btn:disabled { opacity: 0.45; cursor: not-allowed; }
.btn-primary { background: var(--accent); border-color: var(--accent); color: #fff; }
```

- [ ] **Step 5: Test, build, lint**

Run: `cd extension && npm test && npm run build && npm run build:firefox && npm run lint:firefox`
Expected: `Tests  36 passed (36)`; `dist/` and `dist-firefox/` each hold `background.js manifest.json popup.css popup.html popup.js theme.js` and nothing else; lint summary `errors 0, notices 0, warnings 0`.

- [ ] **Step 6: Commit**

```bash
git add extension
git commit -m "extension: background wiring and popup"
```

---

### Task 8: Development native host and live check

**Files:**
- Create: `extension/scripts/register-dev-host.sh`, `extension/scripts/live-check/run.sh`, `extension/scripts/live-check/check.mjs`
- Modify: `extension/src/background/helper.ts` (`connectHelper` also reads Firefox's `port.error`)

What running this found (2026-11-05):
- macOS won't let a browser start a program inside `~/Documents` (`Operation not permitted`), so the dev host is a copy of the helper in `~/Library/Application Support/Tortuga/dev/` with `pt/` next to it, not a script in the repo.
- Firefox reports a closed native port in `port.error`, not `runtime.lastError` (and gives no reason at all when the program can't be started); the helper's stderr shows in the browser console.
- WebDriver BiDi can't navigate to `moz-extension://`; the live check opens the popup page from the browser's privileged scope (`MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1`, `--remote-allow-system-access`).
- Firefox's own background requests (`mozilla.org`, `devtools`) also go through Tor, each with its own circuit.

- [ ] **Step 1: Write the scripts** — `register-dev-host.sh` copies `helper/target/release/tortuga-helper` and `helper/resources/pt/{lyrebird,pt_config.json}` to the dev dir and writes the host manifest for Firefox, and for Chrome when given an extension id. `live-check/run.sh` builds the Firefox extension, registers the host, starts headless Firefox through `web-ext` with BiDi on port 9222, and runs `check.mjs`. See the files in the repository for their content.

- [ ] **Step 2: Live check in Firefox (automated)**

Run: `(cd helper && cargo build --release -p tortuga-helper && scripts/fetch-pt.sh) && extension/scripts/live-check/run.sh`
Expected, ending with `ALL PASSED` (measured: Tor on via Snowflake in about 10 s on a cold profile):
`PASS starts off`, `PASS Tor on`, check.torproject.org `IsTor true`, `PASS circuit events for both sites`, `PASS different circuits per site`, `PASS first hop is the Snowflake bridge`, `PASS resistFingerprinting: sites see UTC`, `PASS new circuit has a new path`, `PASS popup shows failed`, `PASS nothing loads (cache-busted) while failed` (`NS_ERROR_PROXY_CONNECTION_REFUSED`), `PASS back on after Restart`, `PASS off`, `PASS pages load directly again`, `PASS resistFingerprinting released`.
Pages visited before the helper died can still show from the browser cache; nothing new goes out.

- [ ] **Step 3: Live check in Chrome (by hand)**

Branded Chrome 137+ ignores `--load-extension`, so this one stays manual:
1. `cd extension && npm run build`; in `chrome://extensions` turn on Developer mode, **Load unpacked** → `extension/dist`, copy the extension id, open **Details** → turn on **Allow in Incognito**.
2. Run: `extension/scripts/register-dev-host.sh <that id>`.
3. Turn Tor on from the popup; in an incognito window `https://check.torproject.org/` says Tor; a regular window says not Tor.
4. Turn off **Allow in Incognito**, turn Tor on again: the popup shows the incognito message and nothing starts.

- [ ] **Step 4: Commit**

```bash
git add extension/scripts extension/src/background/helper.ts
git commit -m "dev: native host install outside Documents and a Firefox live check"
```

---

## Next plans

1. **3b — Popup visuals and settings**: metro diagram from `circuit` events, connecting animation from `tor.status`, bridge picker with mini diagrams (obfs4 / WebTunnel line entry), exit IP, settings page (bridge lines, helper status and version, theme), Nomada's Twemoji flags.
2. **Moat bridges**, 3. **Torrents**, 4. **Installers and release** — as before.
