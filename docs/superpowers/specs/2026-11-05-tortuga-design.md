# Tortuga — design

Date: 2026-11-05
Mockups: `docs/mockups/route-style.html` (option A chosen), `docs/mockups/popup-layout.html`
(option A chosen), `docs/mockups/bridges.html`. The mockups use Russian text for
discussion; the shipped UI is English, like Nomada.

## Goal

A browser extension for Chrome and Firefox that sends the browser's traffic
through Tor, shows the route and the bridge as schematic diagrams, and
downloads files from torrent links. It looks and feels like Nomada: same design
tokens, light and dark themes, plain TypeScript and DOM, Vite.

Tortuga is **not** Tor Browser and must say so. It hides the IP and opens
`.onion` sites; it does not give Tor Browser's anonymity, because the browser's
fingerprint stays that of Chrome or Firefox. The store listing, the popup and
the first-run page all state this.

## Parts

Two programs, one repository:

- `extension/` — the WebExtension (TypeScript + Vite), laid out like Nomada:
  `background/`, `popup/`, `options/`, `content/`, `lib/`, `styles/tokens.css`.
  One code base; the browser is chosen at build time with `__TARGET__`
  (`TARGET=firefox`), output in `dist/` and `dist-firefox/`.
- `helper/` — `tortuga-helper`, a Rust binary the browser starts through native
  messaging. It runs Tor (embedded `arti-client`), reports circuits and
  bootstrap progress, and downloads torrents (`librqbit`). Installers for
  macOS, Windows and Linux register it as a native messaging host for both
  browsers.

An extension cannot run Tor, see circuits or reach ordinary BitTorrent peers by
itself, so the helper is required. Without it the Tor switch is disabled.

## Helper

### Tor

- `arti-client` embedded as a library, version pinned: the circuit-path API
  (`ClientCirc` from a data stream) is behind Arti's experimental features.
- Bridges: none, Snowflake, obfs4, WebTunnel, or user-supplied bridge lines.
  Pluggable transports come from a bundled `lyrebird` binary, launched by Arti
  as a managed transport.
- Bridge lines for obfs4 / WebTunnel are either pasted by the user or fetched
  with **Get … lines** on the settings page: the helper asks the Tor Project's
  Moat service (`circumvention/settings`, which hands out BridgeDB lines where
  Tor is blocked, then `circumvention/builtin`) directly, or through Tor's own
  SOCKS port when that fails and Tor already runs. Snowflake needs no bridge
  lines, so it is the way in where bridges.torproject.org is blocked. No
  domain fronting: meek's front parameters change too often to rely on.
  Moat has no built-in WebTunnel bridges; where it says none are needed, the
  user pastes WebTunnel lines.
- Relay countries come from Arti's offline GeoIP data (`tor-geoip`); no lookup
  service is called. Bridge countries are often unknown (Snowflake always),
  so the bridge station shows its transport, not a country.
- Arti's state and cache go to the helper's own directories
  (`storage.state_dir`, `storage.cache_dir`), not the shared Arti defaults.

### Own SOCKS5 server

Arti's built-in SOCKS proxy is not used. The helper runs its own SOCKS5
server on `127.0.0.1` with a random free port and reports the port to the
extension.

- Each distinct SOCKS username gets its own Arti isolation token, so it gets
  its own circuits. In Firefox the username is the site (see Routing); in
  Chrome there is no username and everything shares one isolation key,
  `default`.
- After a stream opens, the helper reads that stream's circuit path and emits
  a `circuit` event for the isolation key whenever the path differs from the
  last one sent.
- Host names are resolved by Tor (SOCKS5 with domain names), never locally.
- The port takes no password: Chrome can't send one. Any program of the same
  user (or another user on a shared machine) can use Tor through it while it
  is open, and can name any site as its username. Accepted for a desktop
  helper; the port is random, on loopback only, and closed when Tor stops.
- At most 1000 sites keep their isolation token and last path; past that an
  arbitrary one is forgotten (its next streams get new circuits). A bridge
  change forgets all of them, so no site keeps a circuit through the old
  bridges or guard.
- SOCKS errors can name visited sites, so they go to stderr (the browser's
  log) only when `TORTUGA_DEBUG` is set.

### Torrents

- `librqbit`, connected **directly**, not through Tor: the Tor Project asks
  people not to run BitTorrent over Tor, and the protocol can reveal the real
  IP anyway. Every place a download starts says "Downloads from your IP, not
  through Tor".
- Files go to `~/Downloads/Tortuga/`, fixed in v1 and shown on the settings
  page.
- A finished torrent shares until it has uploaded one copy of itself since it
  last started, then pauses (the Downloads tab says "not sharing"; ▶ shares
  one more copy). Removing it stops sharing and asks whether to delete the
  files.
- Only one helper at a time opens the torrent list (a lock file in its state
  folder): another browser's helper says the downloads are open elsewhere
  instead of writing the same files.
- Looking a torrent up (`torrent.inspect`) gives up after 3 minutes; closing
  the confirm window forgets its torrent.
- The session opens on the first torrent request, or on `torrent.open`, which
  the extension sends on startup when there were downloads, so they resume. The extension talks to it
  over a **second native port** — a second helper process — so downloads run
  with Tor on or off and the two processes never share state.
- A torrent's id is its info hash, stable across restarts.
- `.torrent` URLs are fetched by the helper itself, without the browser's
  cookies: private trackers that need a login are not supported in v1.
- Nothing about a torrent reaches the network before the user acts, and never
  around Tor: the link catcher takes only trusted clicks; while Tor covers the
  link (Firefox: Tor on; Chrome: Tor on and an Incognito tab, or unknown), a
  `.torrent` URL goes to the torrent helper with `via: { socksPort, site }` and
  is fetched through the Tor helper's SOCKS port, or refused while Tor isn't
  ready; a magnet is looked up only after the confirm window asks, since its
  lookup reaches peers and trackers from the user's IP. Helpers list
  `torrent-via-tor` in their hello's `features`; the extension never sends
  `via` to one that doesn't (an older helper would ignore it and fetch directly).

### Lifetime

The browser starts the helper when the extension calls `connectNative` and
ends it when the port closes. An open native port keeps Chrome's service
worker alive. Turning Tor on starts a helper; a bridge change or **Restart**
after a failed start asks the same helper again (it switches its running
client and proves the new bridges, see Known limitations); **Direct** closes
it. Closing the browser stops Tor and all downloads; on next start
unfinished torrents resume (the helper keeps its torrent list on disk).

## Protocol

Native messaging, JSON messages `{ id, type, payload }`. Replies carry the
request's `id`; events have none.

The first message is `hello { protocol }`. If the helper's protocol version is
not the one the extension expects, the popup asks to update the helper and the
Tor switch stays off. The reply is `hello { protocol, version, features }`:
`features` lists additions to protocol 1 (`torrent-via-tor`, `torrent-open`);
the extension uses one only when the helper lists it.

Extension → helper:

| type | payload |
|---|---|
| `tor.start` | `{ bridge: { kind: 'none' \| 'snowflake' \| 'obfs4' \| 'webtunnel', lines?: string[] } }` |
| `tor.stop` | — |
| `tor.newCircuit` | `{ site }` — new isolation token for that site (`default` in Chrome) |
| `bridges.fetch` | `{ kind: 'obfs4' \| 'webtunnel' }` → reply `bridges.lines { lines, source: 'bridgedb' \| 'builtin', country, viaTor }`; failures → `error { code: 'bridges_failed' }` (Moat's "none needed here" is passed on as is, without retrying through Tor) |
| `torrent.inspect` | `{ source: { url } \| { torrentFile: base64 } }` → reply `torrent.info { id, name, size, files, folder }`, nothing downloaded |
| `torrent.add` | same `source` → reply `torrent.info` |
| `torrent.open` | — → `ok` once the torrent list is open (saved downloads resume) |
| `torrent.pause` / `torrent.resume` | `{ id }` → `ok` |
| `torrent.remove` | `{ id, deleteFiles }` → `ok` |

Replies: `tor.start` → `tor.ready { socksPort }`; `tor.stop` and
`tor.newCircuit` → `ok`; any failure → `error { code, message }` with the
request's `id` (also for a request that didn't parse, when it has one).
Codes: `bad_request`, `hello_required`, `protocol_mismatch`, `tor_failed`,
`not_running`, `torrent_failed`, `bridges_failed`, `cancelled` (a newer
`tor.start` or a `tor.stop` replaced this start), `internal` (the answer was
too large to send).

Helper → extension (events):

| type | payload |
|---|---|
| `tor.status` | `{ phase: 'bridge' \| 'directory' \| 'ready', percent, blocked }` |
| `circuit` | `{ site, bridge: 'snowflake' \| 'obfs4' \| 'webtunnel' \| null, hops: [{ role: 'guard' \| 'bridge' \| 'middle' \| 'exit', id, addr, country }] }` — `addr` is the relay's address (a placeholder for Snowflake) |
| `torrent.progress` | `{ torrents: [{ id, name, done, size, downRate, upRate, state: 'starting' \| 'downloading' \| 'seeding' \| 'paused' \| 'error', error }] }` every second while there are torrents, once more when the list empties; failures → `error { code: 'torrent_failed' }` |
| `error` | `{ code, message, torrentId? }` |

Arti reports one bootstrap fraction (15 % first hop, 85 % directory); the
phases follow that split. There is no separate circuit phase. `blocked` is
Arti's own reason when it thinks bootstrap is stuck, else `null`. `country` is
`null` when unknown (always for Snowflake).

## Extension

### Routing

- **Firefox:** `proxy.onRequest` answers every request while Tor is on with
  `{ type: 'socks', host: '127.0.0.1', port: socksPort, proxyDNS: true,
  username: site, password: 'x' }` and no fallback, like Nomada's
  `firefox-proxy.ts`. `site` is the registrable domain of the top-level page
  (from `frameAncestors`, or the request URL for `main_frame`), so each site
  gets its own circuit. The registrable domain comes from the public suffix
  list bundled with the extension (`tldts`); browsers expose no API for it. While Tor is on, the extension also sets
  `privacy.websites.resistFingerprinting` and
  `privacy.network.peerConnectionEnabled = false`, and restores them when Tor
  is turned off. These apply to the whole browser.
- **Chrome:** Tor applies only to incognito windows:
  `chrome.proxy.settings.set({ scope: 'incognito_persistent' })` (not
  `incognito_session_only`: Chrome refuses it while no Incognito window is open
  and drops it when the last one closes) with a
  fixed SOCKS5 server, and `webRTCIPHandlingPolicy = disable_non_proxied_udp`.
  The extension needs "Allow in Incognito"; until it has it, the popup explains
  how to grant it. One circuit for everything; the popup says protection is
  weaker than in Firefox. Regular windows are untouched.
- **New circuit** sends `tor.newCircuit` for the active tab's site.

### Popup (two tabs)

- Top: the Nomada-style segmented switch **Direct / Tor**.
- **Route** tab: the metro diagram for the active tab's site — You → bridge or
  guard → middle → exit → site. Relay stations carry country flags (Twemoji font,
  as in Nomada) and the country code; the bridge station shows its transport
  instead. The bridge station's shape and the line segment it covers show
  the transport: dotted for Snowflake, wavy for obfs4, tube for WebTunnel.
  When the circuit changes, a station whose relay changed fades in (stations
  are keyed `role:relayId`). The site's name sits above the end station,
  right-aligned; a long one drops its last label (`wikipedia.org` →
  `wikipedia`) before it is cut. A tab that isn't a web page shows "No site"
  (Firefox); Chrome's shared circuit shows "Incognito". Below: the bridge
  picker (the bridge list with a mini diagram per type; obfs4 and WebTunnel
  only with saved lines), **New circuit**, and "Exit relay ‹addr› · ‹country›"
  — the exit relay's address, which is normally the address sites see.
- While connecting, the same line lights up station by station from
  `tor.status` phases (first hop, directory, ready), with a percentage;
  **Direct** cancels.
- **Downloads** tab (badge shows active count): one row per torrent with
  name, progress bar, speed and state, pause/resume/remove, and the
  "from your IP" warning.
- Light and dark themes from the shared tokens, picked as in Nomada.

### Starting a download

- A content script catches clicks on `magnet:` links and links to `.torrent`
  files.
- Context menu on links: **Download with Tortuga**.
- Paste field on the Downloads tab (magnet link or `.torrent` file).

Each one opens a small extension window to confirm: name, size, number of
files, destination, and the "from your IP, not through Tor" note. The
background keeps the pending torrent under a one-time token in the window's
URL; the window inspects it first (a magnet needs peers to describe it — after
8 s the window says so) and adds it only on **Download**. Only magnets with a
BitTorrent info hash and http(s) links ending in `.torrent` are taken.

### Settings page

Download folder (shown, not changeable in v1), bridge lines, helper status and version, theme (System /
Light / Dark). Bridge lines are checked on Save — transport, address:port,
40-character fingerprint, with the failing line named — and stored as
`Bridge …` lines under `tortugaBridgeLines`.

## Errors

The rule from Nomada: nothing leaks, and the popup says why.

- **Helper not installed** (`connectNative` fails): the Tor switch is disabled
  and replaced by **Install helper**, linking to the latest release.
- **Helper outdated:** same, with **Update helper**.
- **No bootstrap progress for 30 s:** the popup offers another bridge type.
  Cold starts through Snowflake took 11 s, 22 s and about 100 s in test runs, so a fixed
  30 s limit would fire on healthy starts.
- **Helper dies while Tor is on:** the proxy keeps pointing at the dead port,
  so requests fail instead of going direct. The popup turns red and offers
  **Restart**, which reconnects and starts Tor again.
- **Torrent errors** (no peers, disk full, bad link) show in that download's
  row.

Known limitations (found while testing):

- A bridge change on a running client is proven before `tor.ready`: Arti
  says it is ready at once (the directory is cached), so the helper opens test
  streams to check.torproject.org on fresh circuits until one runs through a
  new bridge (to no bridge: not through an old one), for up to 5 minutes, then
  gives up with "the new bridges didn't answer". Meanwhile `tor.status` says
  `bridge` (the first-hop step). A further new circuit can still try a dead
  bridge from the same set first, so a first page may need a retry
  (`helper/scripts/switch_check.py` checks this).
- Built-in obfs4 bridges don't all answer from every network (1 of 3 from the
  test network); Arti tries them in turn, so a first start on them took 1½–5
  minutes. Cold Snowflake starts ranged from 11 s to about 5 minutes on the
  same network on different days.
- Arti refuses to keep state under a group- or world-writable directory
  (`problem with filesystem permissions`); the default data dir is fine, test
  runs keep their data under `helper/target/`.

## Testing

- **First implementation step — spike:** a minimal Rust program that
  bootstraps Arti, opens two streams with different isolation tokens and
  prints each stream's circuit path and relay countries. If Arti cannot
  provide this, stop and revisit the helper choice before building anything
  else.
- **Extension:** vitest, as in Nomada — Firefox routing (site → username,
  no direct fallback), Chrome incognito scope, protocol parsing, metro layout
  as a pure function (circuit → station positions), magnet / `.torrent` link
  detection.
- **Helper:** `cargo test` for the protocol framing, the SOCKS5 server and
  username → isolation mapping, torrent state persistence. A manual
  integration run against the real Tor network before each release.

## Release

- Extension: Chrome Web Store (`tortuga-chrome-<v>.zip`, without the
  manifest's "key") and AMO (`tortuga-firefox-<v>.zip` plus a source zip that
  rebuilds it byte for byte).
- Helper, from the GitHub release: macOS `.pkg` (universal; signed and
  notarised when the Developer ID secrets exist) installing to
  `/Library/Application Support/Tortuga/`; Debian `.deb` for amd64 and arm64
  installing to `/usr/lib/tortuga/`; Windows zip with `install.ps1`, a
  per-user install to `%LOCALAPPDATA%\Tortuga` registered in `HKCU` (no admin
  rights). No AppImage: a native host must be registered in fixed places,
  which an AppImage doesn't do. Each installer bundles `lyrebird` and
  `pt_config.json` from Tor Expert Bundle 16.0 for its platform.
- Native host manifests come from `helper/packaging/hosts.py`. The Chrome
  extension ID is pinned with a key generated once (`hosts.py
  set-chrome-key`); until then installers register Firefox only.
- `RELEASE.md` has the steps; CI (`.github/workflows/release.yml`) builds,
  installs and smoke-tests every package and publishes the release on a
  `v*` tag.

## Not in the first version

Hosting `.onion` services, streaming video from torrents, a configurable
seeding ratio, running the helper without the browser, routing torrents through a
proxy or VPN, localization beyond English.
