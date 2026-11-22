# Remove torrents — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove torrent downloading from the helper, the browser extension, the macOS app and the docs, without breaking Tor, bridges or Moat.

**Architecture:** Spec: `docs/superpowers/specs/2026-11-22-no-torrents-and-route-map-design.md`, step 1. The helper drops its torrent requests and stops listing the `torrent-*` features, so an old extension stops offering torrents. The extension's `Downloads` class also fetched Moat bridge lines while Tor was off; that one job moves to a small `DirectHelper`. Everything else torrent-related is deleted.

**Tech Stack:** Rust (helper, Arti, tokio, serde), TypeScript + Vite + Vitest (extension), Swift 6 + SwiftUI + swift-testing (macOS app).

**Branch:** `feat/remove-torrents` (already created; the spec is its first commit).

---

## File map

Helper (`helper/tortuga-helper/`):
- Delete: `src/torrents.rs`
- Modify: `src/protocol.rs` (torrent requests, messages, error code, features), `src/app.rs` (dispatch, torrent session, progress), `src/config.rs` (downloads folder, torrent state), `src/main.rs` (module, a test), `Cargo.toml` and `../Cargo.lock` (librqbit, librqbit-core, base64)
- Delete: `helper/scripts/torrent_check.py`
- Modify: `helper/packaging/linux/build-deb.sh` (package description)

Extension (`extension/`):
- Create: `src/background/direct-helper.ts`, `tests/direct-helper.test.ts`
- Delete: `src/background/downloads.ts`, `src/lib/downloads.ts`, `src/lib/torrent-route.ts`, `src/content/links.ts`, `src/confirm/` (whole folder), `src/popup/downloads.ts`, `vite.config.content.ts`, `vite.config.confirm.ts`, `tests/downloads.test.ts`, `tests/downloads-lib.test.ts`, `tests/torrent-route.test.ts`, `scripts/live-check/downloads.mjs`, `scripts/live-check/site/links.html`
- Modify: `src/background/index.ts`, `src/lib/messages.ts`, `src/lib/protocol.ts`, `src/lib/senders.ts`, `tests/senders.test.ts`, `src/popup/index.html`, `src/popup/index.ts`, `src/popup/style.css`, `src/options/index.html`, `src/options/index.ts`, `manifest.json`, `manifest.firefox.json`, `package.json`, `scripts/live-check/run.sh`, `scripts/live-check/screenshots.mjs`, `BUILD.md`

macOS (`macos/Packages/`):
- Delete: `TortugaUI/Sources/TortugaUI/DownloadsView.swift`
- Modify: `TortugaKit/Sources/TortugaKit/Models.swift`, `TortugaEngine.swift`, `DemoEngine.swift`, `DemoData.swift`; `TortugaKit/Tests/TortugaKitTests/CodableTests.swift`, `DemoEngineCommandTests.swift`; `TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift` and its tests; `TortugaUI/Sources/TortugaUI/MainWindow.swift`, `AppModel.swift`, `Previews.swift`; UI tests under `macos/TortugaUITests/` (whichever mention Downloads)

Docs: `README.md`, `PRIVACY.md`, `.github/release-notes.md`, `store-assets/src/slides.html`, `macos/README.md` (if it mentions downloads).

---

### Task 1: Helper protocol without torrents

**Files:**
- Modify: `helper/tortuga-helper/src/protocol.rs`

- [ ] **Step 1: Change the tests first**

In `protocol.rs`'s `mod tests`:
- Delete the tests `parses_torrent_requests`, `decodes_sources` and `serializes_torrent_messages`.
- In the test that parses `tor.stop` (around line 233), delete the line asserting `torrent.open` parses.
- In `serializes_replies_and_events`, change the hello assertion's features to `["apps"]`:

```rust
        assert_eq!(hello, json!({"id": 1, "type": "hello", "payload": {"protocol": 1, "version": "0.1.1", "features": ["apps"]}}));
```

- Add, next to `rejects_unknown_type`:

```rust
    #[test]
    fn torrent_requests_are_unknown() {
        for t in ["torrent.open", "torrent.inspect", "torrent.add", "torrent.pause", "torrent.resume", "torrent.remove"] {
            assert!(serde_json::from_value::<Request>(json!({"id": 1, "type": t, "payload": {"id": "ab"}})).is_err(), "{t}");
        }
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd helper && cargo test -p tortuga-helper protocol::`
Expected: FAIL — `torrent_requests_are_unknown` (torrent requests still parse) and the hello features assertion.

- [ ] **Step 3: Remove torrents from the protocol**

In `protocol.rs`:
- Delete `use crate::torrents::{Progress, Source, TorrentInfo};`.
- Replace the features doc comment and constant with:

```rust
/// Additions to protocol 1 this helper understands, listed in its hello so the
/// extension never relies on one an older helper would silently ignore.
/// `apps`: `tor.resolve`, for a client whose isolation keys are apps.
/// (Helpers up to 0.2.1 also listed `torrent-via-tor` and `torrent-open`.)
pub const FEATURES: &[&str] = &["apps"];
```

- In `RequestBody`, delete the variants `TorrentInspect`, `TorrentAdd`, `TorrentOpen`, `TorrentPause`, `TorrentResume`, `TorrentRemove`.
- Delete `enum SourceMsg` with its `impl` and `struct Via`.
- In `Outgoing`, delete `TorrentInfo(TorrentInfo)` and `TorrentProgress { … }`.
- In `ErrorCode`, delete `TorrentFailed`.

The crate won't compile yet (`app.rs`, `main.rs` still use these); Task 2 fixes that. Don't commit yet.

### Task 2: Helper without the torrent session

**Files:**
- Delete: `helper/tortuga-helper/src/torrents.rs`
- Modify: `helper/tortuga-helper/src/app.rs`, `src/config.rs`, `src/main.rs`, `Cargo.toml`, `helper/Cargo.lock`

- [ ] **Step 1: `app.rs`**

- Module doc at the top becomes:

```rust
//! Handles requests from the extension: hello, then Tor (start, stop, new
//! circuit, resolve) and bridge lines. Long work runs in tasks, so a
//! `tor.stop` can cancel a start and a slow request doesn't hold up others.
```

- Imports: `use tokio::sync::Mutex;` (drop `OnceCell`), drop `use std::time::Duration;`, and the protocol import becomes
  `use crate::protocol::{BridgeChoice, ErrorCode, FEATURES, Message, Outgoing, PROTOCOL_VERSION, Request, RequestBody};`.
  Delete `use crate::torrents::{Link, Source, Torrents};`.
- Delete `PROGRESS_EVERY`, `enum TorrentJob`, the `torrents` field of `App`, so:

```rust
#[derive(Clone)]
pub struct App {
    state: Arc<Mutex<State>>,
    paths: Paths,
    events: Events,
}

impl App {
    pub fn new(paths: Paths, events: Events) -> Self {
        Self { state: Arc::default(), paths, events }
    }
```

- In `handle`, delete the six `RequestBody::Torrent…` arms.
- Delete the methods `torrent`, `run_torrent`, `open_torrents`, and the free functions `link` and `report_progress`.
- Tests: delete `links_never_go_around_tor`; in `fn app()` delete the `downloads` and `torrent_state` fields from the `Paths` literal.

- [ ] **Step 2: `config.rs`**

- Delete the `downloads` and `torrent_state` fields of `Paths`, the `downloads_dir` function and its test `downloads_folder_falls_back_to_home`.
- `discover()` becomes:

```rust
    pub fn discover() -> anyhow::Result<Self> {
        let (state_dir, cache_dir) = match std::env::var_os("TORTUGA_DATA_DIR") {
            Some(d) => {
                let d = PathBuf::from(d);
                (d.join("state"), d.join("cache"))
            }
            None => {
                let dirs = directories::ProjectDirs::from("org", "Tortuga", "tortuga-helper")
                    .ok_or_else(|| anyhow::anyhow!("no home directory"))?;
                (dirs.data_dir().join("arti-state"), dirs.cache_dir().join("arti-cache"))
            }
        };
        let pt_dir = match std::env::var_os("TORTUGA_PT_DIR") {
            Some(d) => PathBuf::from(d),
            None => std::env::current_exe()?
                .parent()
                .ok_or_else(|| anyhow::anyhow!("executable has no directory"))?
                .join("pt"),
        };
        let exe = if cfg!(windows) { "lyrebird.exe" } else { "lyrebird" };
        Ok(Self { state_dir, cache_dir, lyrebird: pt_dir.join(exe), pt_config: pt_dir.join("pt_config.json") })
    }
```

Leave users' existing `torrents` data folder alone: deleting user data isn't this change's job.

- [ ] **Step 3: `main.rs`**

Delete `mod torrents;`. In the test `an_oversized_reply_becomes_an_error_and_the_rest_still_go_out`, use `ErrorCode::TorFailed` instead of `ErrorCode::TorrentFailed`.

- [ ] **Step 4: Delete `torrents.rs` and the dependencies**

```bash
git rm helper/tortuga-helper/src/torrents.rs
```

In `helper/tortuga-helper/Cargo.toml` delete the lines `librqbit = "=9.1.0"`, `librqbit-core = "=9.1.0"` and `base64 = "0.22"`. Keep `reqwest` (Moat uses it, `socks` included) and `directories`.

Run: `cd helper && cargo update -p tortuga-helper`
Expected: `Cargo.lock` loses librqbit and the crates only it pulled in.

- [ ] **Step 5: Build, test, lint**

Run: `cd helper && cargo test && cargo clippy --all-targets -- -D warnings`
Expected: all tests pass, no warnings. If clippy reports something now unused (an import, a helper only torrents called), delete it.

Run: `git grep -n -i 'torrent\|rqbit\|magnet' -- helper/tortuga-helper`
Expected: only the `FEATURES` comment line about 0.2.1 and the new `torrent_requests_are_unknown` test.

- [ ] **Step 6: Commit**

```bash
git add -A helper/tortuga-helper helper/Cargo.lock
git commit -m "feat(helper)!: remove torrents

The helper no longer downloads torrents: no torrent.* requests, no
librqbit, and its hello lists only the apps feature, so an older extension
stops offering torrents."
```

### Task 3: Helper scripts and packaging

**Files:**
- Delete: `helper/scripts/torrent_check.py`
- Modify: `helper/packaging/linux/build-deb.sh:50-53`

- [ ] **Step 1: Remove and reword**

```bash
git rm helper/scripts/torrent_check.py
```

In `build-deb.sh`, the `Description:` line becomes `Description: Tor for the Tortuga browser extension`, and the long description loses the sentence part about torrent downloads (end the sentence after the bundled lyrebird mention). Keep the Debian control format: continuation lines start with one space.

Run: `git grep -n -i 'torrent\|TORTUGA_DOWNLOADS' -- helper .github`
Expected: nothing outside `helper/tortuga-helper/src` (Task 2's two lines).

- [ ] **Step 2: Check the package still builds (Linux only; on macOS check the script's syntax)**

Run: `bash -n helper/packaging/linux/build-deb.sh`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add -A helper
git commit -m "chore(helper): drop torrent scripts and package wording"
```

### Task 4: Extension — `DirectHelper` for Moat while Tor is off

**Files:**
- Create: `extension/src/background/direct-helper.ts`
- Test: `extension/tests/direct-helper.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from 'vitest';
import { DirectHelper } from '../src/background/direct-helper';
import { HelperClient } from '../src/background/helper';
import { FakePort, flush } from './fake-port';

function setup(lastError?: string) {
  const ports: FakePort[] = [];
  const direct = new DirectHelper({
    connect: (onEvent, onGone) => {
      const port = new FakePort();
      ports.push(port);
      return new HelperClient(port, onEvent, onGone, () => lastError);
    },
  });
  return { direct, ports };
}

async function hello(ports: FakePort[]) {
  await flush();
  const port = ports.at(-1)!;
  port.emit({ id: port.idOf('hello'), type: 'hello', payload: { protocol: 1, version: '0.3.0', features: ['apps'] } });
  await flush();
  return port;
}

describe('DirectHelper', () => {
  it('says hello, then fetches bridge lines', async () => {
    const { direct, ports } = setup();
    const fetching = direct.fetchBridges('obfs4');
    const port = await hello(ports);
    expect(port.sent[1]).toMatchObject({ type: 'bridges.fetch', payload: { kind: 'obfs4' } });
    port.emit({ id: port.idOf('bridges.fetch'), type: 'bridges.lines', payload: { lines: ['obfs4 a'], source: 'moat', country: null, viaTor: false } });
    await expect(fetching).resolves.toMatchObject({ lines: ['obfs4 a'] });
  });

  it('passes the helper’s error on', async () => {
    const { direct, ports } = setup();
    const fetching = direct.fetchBridges('webtunnel');
    const port = await hello(ports);
    port.emit({ id: port.idOf('bridges.fetch'), type: 'error', payload: { code: 'bridges_failed', message: 'none are needed here' } });
    await expect(fetching).rejects.toThrow('none are needed here');
  });

  it('reuses one port, and reconnects after the helper goes away', async () => {
    const { direct, ports } = setup('Specified native messaging host not found.');
    const first = direct.fetchBridges('obfs4');
    await flush();
    ports[0].die();
    await expect(first).rejects.toThrow();
    void direct.fetchBridges('obfs4').catch(() => undefined);
    await flush();
    expect(ports).toHaveLength(2);
  });
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd extension && npx vitest run tests/direct-helper.test.ts`
Expected: FAIL — cannot find module `../src/background/direct-helper`.

- [ ] **Step 3: Write `direct-helper.ts`**

```ts
import { PROTOCOL_VERSION, type FetchedLines, type HelperMessage } from '../lib/protocol';
import { linesOf } from './controller';
import type { HelperClient } from './helper';

/** What DirectHelper needs from the outside world (a fake port in tests). */
export interface DirectDeps {
  connect(onEvent: (m: HelperMessage) => void, onGone: (reason: string) => void): HelperClient;
}

/**
 * A helper on a native port of its own that never runs Tor: while Tor is off,
 * it asks Moat for bridge lines directly. Opened on first use and kept while
 * the browser runs; a new one is opened if it goes away.
 */
export class DirectHelper {
  private ready: Promise<HelperClient> | null = null;

  constructor(private readonly deps: DirectDeps) {}

  async fetchBridges(kind: 'obfs4' | 'webtunnel'): Promise<FetchedLines> {
    const helper = await this.client();
    return linesOf(await helper.request({ type: 'bridges.fetch', payload: { kind } }));
  }

  private client(): Promise<HelperClient> {
    if (!this.ready) {
      const ready = (async () => {
        const helper = this.deps.connect(() => undefined, () => {
          if (this.ready === ready) this.ready = null;
        });
        await helper.request({ type: 'hello', payload: { protocol: PROTOCOL_VERSION } });
        return helper;
      })();
      this.ready = ready;
      ready.catch(() => {
        if (this.ready === ready) this.ready = null;
      });
    }
    return this.ready;
  }
}
```

- [ ] **Step 4: Run it to see it pass**

Run: `cd extension && npx vitest run tests/direct-helper.test.ts`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add extension/src/background/direct-helper.ts extension/tests/direct-helper.test.ts
git commit -m "feat(extension): DirectHelper fetches bridge lines while Tor is off"
```

### Task 5: Extension — background and messages without torrents

**Files:**
- Modify: `extension/src/background/index.ts`, `src/lib/messages.ts`, `src/lib/protocol.ts`, `src/lib/senders.ts`, `tests/senders.test.ts`
- Delete: `src/background/downloads.ts`, `src/lib/downloads.ts`, `src/lib/torrent-route.ts`, `tests/downloads.test.ts`, `tests/downloads-lib.test.ts`, `tests/torrent-route.test.ts`

- [ ] **Step 1: Change the senders test first**

Replace `tests/senders.test.ts` with:

```ts
import { describe, it, expect } from 'vitest';
import { senderAllowed } from '../src/lib/senders';

const ID = 'abcdefghijklmnop';
const URL = `chrome-extension://${ID}/`;

describe('senderAllowed', () => {
  it('lets Tortuga’s own pages send anything', () => {
    expect(senderAllowed({ id: ID, url: `${URL}popup.html` }, ID, URL)).toBe(true);
    expect(senderAllowed({ id: ID, url: `${URL}options.html` }, ID, URL)).toBe(true);
  });

  it('refuses web pages, even with the extension’s id', () => {
    expect(senderAllowed({ id: ID, url: 'https://example.org/' }, ID, URL)).toBe(false);
  });

  it('refuses other extensions', () => {
    expect(senderAllowed({ id: 'other', url: `${URL}popup.html` }, ID, URL)).toBe(false);
  });

  it('does not take a look-alike origin for its own', () => {
    expect(senderAllowed({ id: ID, url: `https://evil.example/?${URL}` }, ID, URL)).toBe(false);
  });
});
```

Run: `cd extension && npx vitest run tests/senders.test.ts`
Expected: FAIL (the function still takes a message type first).

- [ ] **Step 2: `senders.ts`**

```ts
/**
 * Who may send messages to the background: only Tortuga's own pages (popup,
 * settings). Nothing runs in web pages any more, so nothing there may ask.
 */
export interface SenderLike {
  id?: string;
  url?: string;
}

/** `ownId` / `ownUrl`: chrome.runtime.id and chrome.runtime.getURL(''). */
export function senderAllowed(sender: SenderLike, ownId: string, ownUrl: string): boolean {
  return sender.id === ownId && sender.url !== undefined && sender.url.startsWith(ownUrl);
}
```

Run: `cd extension && npx vitest run tests/senders.test.ts`
Expected: 4 passed.

- [ ] **Step 3: `protocol.ts`**

Delete `TorrentSource`, `TorrentVia`, `FEATURE_TORRENT_VIA_TOR`, `FEATURE_TORRENT_OPEN`, `TorrentInfo`, `TorrentState`, `TorrentRow`; the `torrent.info` and `torrent.progress` members of the helper message union; the six `torrent.*` members of the request union; and `'torrent_failed'` from the error code union. Keep `HELPER_DOWNLOAD` (it's the helper's download page, not torrents).

- [ ] **Step 4: `messages.ts`**

- Import line becomes `import type { BridgeKind, FetchedLines } from './protocol';` (keep whichever of these the file still uses; the compiler will tell).
- `BgBroadcast` becomes `export type BgBroadcast = { type: 'STATE'; state: TorState };`.
- Delete `DownloadsState`, `DlMessage`, `DlResult` and `DOWNLOADS_KEY` with their doc comments.

- [ ] **Step 5: `background/index.ts`**

- Imports: delete the lines importing from `../lib/downloads`, `../lib/torrent-route` and `./downloads`; the messages import becomes
  `import { LINES_KEY, NO_LINES, STORAGE_KEY, type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult, type Stored } from '../lib/messages';`
  and the protocol import becomes `import type { BridgeKind } from '../lib/protocol';`. Delete the `siteOf`/`DEFAULT_SITE` import if nothing else uses it (the compiler will say). Add `import { DirectHelper } from './direct-helper';`.
- Replace the `const downloads = new Downloads(…)` block and the storage `resume()` block with:

```ts
/** Moat while Tor is off, on a helper of its own. */
const direct = new DirectHelper({ connect: connectHelper });
```

- Delete `fromOwnPage`, `pending`, `openConfirm`, `confirmWindows` and its `onRemoved` listener, `result`, `pendingOf`, `runPending`, `MENU_ID` and both context-menu listeners.
- In `fetchBridges`, `downloads.fetchBridges(kind)` becomes `direct.fetchBridges(kind)`.
- The message listener's signature becomes `(msg: BgMessage | BridgesMessage, sender, sendResponse)`, its check `if (!senderAllowed(sender, chrome.runtime.id, chrome.runtime.getURL('')))`, and the `GET_DOWNLOADS` and `TORRENT_*` cases are deleted.

- [ ] **Step 6: Delete the torrent modules and tests**

```bash
cd extension
git rm src/background/downloads.ts src/lib/downloads.ts src/lib/torrent-route.ts tests/downloads.test.ts tests/downloads-lib.test.ts tests/torrent-route.test.ts
```

- [ ] **Step 7: Type check and test**

Run: `cd extension && npm run typecheck && npm test`
Expected: typecheck errors only in `src/popup/*`, `src/options/*`, `src/content/links.ts`, `src/confirm/*` (fixed in Task 6); tests pass. If anything else fails to compile, fix it here.

Don't commit yet: the build is broken until Task 6.

### Task 6: Extension — pages, manifests and build

**Files:**
- Delete: `extension/src/content/links.ts`, `src/confirm/`, `src/popup/downloads.ts`, `vite.config.content.ts`, `vite.config.confirm.ts`
- Modify: `src/popup/index.html`, `src/popup/index.ts`, `src/popup/style.css`, `src/options/index.html`, `src/options/index.ts`, `manifest.json`, `manifest.firefox.json`, `package.json`

- [ ] **Step 1: Delete the pages and their build configs**

```bash
cd extension
git rm -r src/content src/confirm src/popup/downloads.ts vite.config.content.ts vite.config.confirm.ts
```

- [ ] **Step 2: Popup**

`src/popup/index.html`: delete the whole `<nav class="tabs" …>…</nav>` and the whole `<main id="downloads" …>…</main>`. On `<main id="route" …>` remove `role="tabpanel" aria-labelledby="tabRoute"`.

`src/popup/index.ts`: delete `import { renderDownloads } from './downloads';`, drop `type DownloadsState` from the messages import, delete the `else if (msg.type === 'DOWNLOADS') …` line, the whole "Route / Downloads tabs" block (`TAB_KEY`, `tabs`, `showTab`, both listeners, the `localStorage` line), and the `renderDownloads(…)` line in `init()`.

`src/popup/style.css`: delete the `.tabs`, `.tab` and `.badge` rules and the rules used only by the Downloads tab (`.warn`, `.add`, `.add-input`, `.file`, `.dl-error`, `.rows`, `.row…`, `.empty`, `.folder`, and any progress-bar rules). Before deleting each selector, check it isn't used in `index.html` or `view.ts`:

Run: `cd extension && for s in warn add add-input file dl-error rows row empty folder badge; do printf "%s: " $s; grep -c "class=\"[^\"]*\b$s\b\|'$s'\|\"$s\"" src/popup/index.html src/popup/view.ts src/popup/index.ts | paste -sd' ' -; done`
Expected after the HTML edit: `0` everywhere for the deleted selectors; keep any rule whose selector still shows a use.

- [ ] **Step 3: Options**

`src/options/index.html`: delete the `<section class="card">` whose heading is `Downloads`.

`src/options/index.ts`: the messages import becomes `LINES_KEY, NO_LINES, type BgBroadcast, type BgMessage, type BridgeLines, type BridgesMessage, type BridgesResult`; delete `renderDownloads`, `showDownloads`, the `else if (msg.type === 'DOWNLOADS')` line and `void showDownloads();`; the comment above the listener becomes `// Keep up with Tor turned on or off while this page is open.`

- [ ] **Step 4: Manifests**

`manifest.json`:
- `"description": "Routes Incognito windows through Tor with the Tortuga helper. Hides your IP; it is not Tor Browser."`
- delete `"contextMenus"` from `permissions`;
- delete the whole `content_scripts` array.

`manifest.firefox.json`:
- `"description": "Routes Firefox through Tor with the Tortuga helper, one circuit per site. Hides your IP; not Tor Browser."`
- delete `"contextMenus"` from `permissions` (if present), and the whole `content_scripts` array.

Keep `"key"` in the Chrome manifest unchanged: it fixes the extension ID the helper accepts.

- [ ] **Step 5: `package.json` build script**

```json
    "build": "npm run typecheck && npm run build:background && npm run build:theme && npm run build:popup && npm run build:options",
```

and delete the `build:content` and `build:confirm` entries. If `scripts/package.mjs` lists `links.js` or `confirm.html`, delete those entries too:

Run: `cd extension && grep -n 'links\|confirm' scripts/package.mjs vite.config.*.ts`
Expected after edits: no matches.

- [ ] **Step 6: Build and test both targets**

Run: `cd extension && npm test && npm run build && npm run build:firefox && npm run lint:firefox`
Expected: tests pass; both builds succeed; `dist/` has no `links.js` or `confirm.html`; web-ext lint reports 0 errors.

Run: `ls dist dist-firefox | grep -i 'links\|confirm'`
Expected: no output. (If stale files from older builds remain, the build should empty `dist` first; check `emptyOutDir` in the Vite configs and delete stale files by hand once.)

- [ ] **Step 7: Commit Tasks 5 and 6 together**

```bash
git add -A extension
git commit -m "feat(extension)!: remove torrents

No more magnet and .torrent link catching, confirm window, Downloads tab
or context menu. Web pages can no longer message the background at all.
Bridge lines while Tor is off come from DirectHelper."
```

### Task 7: Extension — live checks and build notes

**Files:**
- Delete: `extension/scripts/live-check/downloads.mjs`, `scripts/live-check/site/links.html`
- Modify: `scripts/live-check/run.sh`, `scripts/live-check/screenshots.mjs`, `BUILD.md`

- [ ] **Step 1: Remove the torrent checks**

```bash
cd extension
git rm scripts/live-check/downloads.mjs scripts/live-check/site/links.html
```

`run.sh`: delete the `downloads` mode from the usage comment, the `[ "$WHAT" = downloads ]` branches, and `export TORTUGA_DOWNLOADS=…` with the `mkdir -p "$TMP/downloads"` line. Other modes keep working as they are.

`screenshots.mjs`: delete the "Confirm window from a magnet link" and "Downloads tab" sections (from the comment `// Confirm window from a magnet link.` through the `shot(popup, 'downloads')` call), the options-page line that rewrites `#downloads`, and the cleanup line that removes downloads; update the header comment so it no longer mentions the Downloads tab. If the script serves `site/links.html`, drop that too.

`BUILD.md`: delete mentions of the content script, the confirm page, `links.js`, torrents and the `contextMenus` permission.

Run: `cd extension && git grep -n -i 'torrent\|magnet\|download' -- . ':!package-lock.json'`
Expected: only `HELPER_DOWNLOAD` and its uses (the helper's download page), and nothing else.

Run: `bash -n scripts/live-check/run.sh && node --check scripts/live-check/screenshots.mjs`
Expected: no output.

- [ ] **Step 2: Commit**

```bash
git add -A extension
git commit -m "chore(extension): drop torrent live checks and build notes"
```

### Task 8: macOS app without downloads

**Files:**
- Delete: `macos/Packages/TortugaUI/Sources/TortugaUI/DownloadsView.swift`
- Modify: see the file map

- [ ] **Step 1: Change the tests first**

- `TortugaKitTests/DemoEngineCommandTests.swift`: delete `@Suite struct DemoEngineDownloads` and everything in it.
- `TortugaKitTests/CodableTests.swift`: delete the line `state.downloadsAvailable = false`.
- `TortugaProxyKitTests/ProxyEngineTests.swift`: delete any test about downloads (`downloadsLater`, `downloadsAvailable`).
- Add to `TortugaKitTests/ModelsTests.swift`:

```swift
@Test func stateHasNoDownloads() throws {
    let json = try JSONEncoder().encode(EngineState.initial)
    let keys = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys
    #expect(!keys.contains("downloads"))
    #expect(!keys.contains("downloadsAvailable"))
}
```

Run: `cd macos/Packages/TortugaKit && swift test --filter stateHasNoDownloads`
Expected: FAIL (the state still has the keys).

- [ ] **Step 2: TortugaKit**

- `Models.swift`: delete `DownloadState`, `Download`, `DownloadSource`, and in `EngineState` the `downloads` and `downloadsAvailable` properties with their comment.
- `TortugaEngine.swift`: delete the four download commands. The doc comment at the top no longer mentions part 3 as future: "What the interface needs from whatever runs Tor: a stream of states and commands. DemoEngine and ProxyEngine implement it."
- `DemoEngine.swift`: delete `state.downloads = DemoData.downloads()`, `addDownload`, `pauseDownload`, `resumeDownload`, `removeDownload`, `stepDownloads` and its call (`if stepDownloads(step) { changed = true }`), `update(_:_:)`, and the `uploaded` dictionary if nothing else uses it.
- `DemoData.swift`: delete `downloads()`.

Run: `cd macos/Packages/TortugaKit && swift test`
Expected: all pass, including `stateHasNoDownloads`.

- [ ] **Step 3: TortugaProxyKit**

`ProxyEngine.swift`: delete `downloadsLater`, `state.downloadsAvailable = false`, and the four download methods.

Run: `cd macos/Packages/TortugaProxyKit && swift test`
Expected: all pass.

- [ ] **Step 4: TortugaUI**

```bash
git rm macos/Packages/TortugaUI/Sources/TortugaUI/DownloadsView.swift
```

- `MainWindow.swift`: `SidebarSection` becomes `case route, bridges, exceptions`; delete the `.downloads` cases in `title`, `symbol` and the detail `switch`.
- `AppModel.swift`: delete any download action (for example an `.downloads` case of the error-key enum) and anything that only `DownloadsView` used.
- `Previews.swift`: delete the `#Preview("Downloads")` block.

Run: `cd macos/Packages/TortugaUI && swift build && swift test`
Expected: builds and passes.

- [ ] **Step 5: App and UI tests**

Run: `cd macos && git grep -n -i 'download' -- . ':!*.pbxproj'`
Expected: only lines about the helper's own download (e.g. "download the helper"), if any. Delete UI-test steps that open the Downloads section (search `sidebar.downloads`).

Run: `cd macos && xcodegen && xcodebuild -scheme Tortuga -destination 'platform=macOS' build-for-testing 2>&1 | tail -3`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A macos
git commit -m "feat(macos)!: remove downloads

The Downloads section, its models and engine commands are gone; Tortuga
for Mac is Tor only."
```

### Task 9: Docs

**Files:**
- Modify: `README.md`, `PRIVACY.md`, `.github/release-notes.md`, `store-assets/src/slides.html`, `macos/README.md`

- [ ] **Step 1: Find every mention**

Run: `git grep -n -i 'torrent\|magnet\|downloads tab\|TORTUGA_DOWNLOADS' -- README.md PRIVACY.md .github store-assets macos/README.md`

- [ ] **Step 2: Rewrite**

For each match: delete the sentence or bullet, or reword so the text describes Tortuga as it is now: Tor for the browser (and for the whole Mac in the app), with routes shown. Specifically:
- `.github/release-notes.md`: the first sentence becomes "Tortuga sends your browser through Tor and draws the route each site takes. It hides your IP; it is not Tor Browser. …"; the helper table's intro becomes "The helper is the small program that runs Tor."; delete the bullet "**Torrents don't go through Tor.** …".
- `PRIVACY.md`: delete what it says about torrents (peers seeing your IP, the downloads folder, `.torrent` fetching); keep everything about Tor and Moat.
- `README.md`: delete the torrent feature, its how-to, and its caveats; keep the uninstall notes.
- `store-assets/src/slides.html`: delete or reword slides and captions about torrents. Rebuilding the store images is out of scope; note in the PR that they need re-rendering before the next store upload.
- Old specs and plans in `docs/superpowers` stay as they are.

Run: `git grep -n -i 'torrent\|magnet' -- . ':!docs/superpowers' ':!*.lock' ':!extension/package-lock.json'`
Expected: only `helper/tortuga-helper/src/protocol.rs` (the 0.2.1 comment and the `torrent_requests_are_unknown` test).

- [ ] **Step 3: Commit**

```bash
git add -A README.md PRIVACY.md .github store-assets macos/README.md
git commit -m "docs: Tortuga no longer downloads torrents"
```

### Task 10: Full check and PR

- [ ] **Step 1: Everything green locally**

Run each, expect success:
- `cd helper && cargo test && cargo clippy --all-targets -- -D warnings`
- `cd extension && npm test && npm run build && npm run build:firefox && npm run lint:firefox`
- `cd macos/Packages/TortugaKit && swift test`, then the same in `TortugaProxyKit` and `TortugaUI`
- `cd macos && xcodebuild -scheme Tortuga -destination 'platform=macOS' build-for-testing`

- [ ] **Step 2: Live check on the user's Mac**

Install the dev build with `macos/scripts/install-dev.sh`, switch to Tor and run `macos/scripts/live-check.sh`. Expected: the same results as before (through Tor, per-app exits, DNS through Tor). Load the unpacked Chrome extension from `extension/dist`: Tor on and off works, Get obfs4 lines works with Tor off (DirectHelper) and on.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/remove-torrents
gh pr create --title "Remove torrents" --body-file -
```

Body: what was removed in each part, the compatibility note (old extension + new helper stops offering torrents; new extension + old helper works), that the store images need re-rendering, and the test results.
