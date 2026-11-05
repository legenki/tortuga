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
  with **Get a bridge**: the helper asks the Tor Project's Moat service over
  the meek transport, as Tor Browser's Connection Assist does. Snowflake needs
  no bridge lines.
- Relay countries come from Arti's offline GeoIP data (`tor-geoip`); no lookup
  service is called.

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

### Torrents

- `librqbit`, connected **directly**, not through Tor: the Tor Project asks
  people not to run BitTorrent over Tor, and the protocol can reveal the real
  IP anyway. Every place a download starts says "Downloads from your IP, not
  through Tor".
- Files go to `~/Downloads/Tortuga/` (changeable on the settings page).
- A torrent seeds while it stays in the list; removing it stops seeding and
  asks whether to delete the files.

### Lifetime

The browser starts the helper when the extension calls `connectNative` and
ends it when the port closes. An open native port keeps Chrome's service
worker alive. Closing the browser stops Tor and all downloads; on next start
unfinished torrents resume (the helper keeps its torrent list on disk).

## Protocol

Native messaging, JSON messages `{ id, type, payload }`. Replies carry the
request's `id`; events have none.

The first message is `hello { protocol }`. If the helper's protocol version is
not the one the extension expects, the popup asks to update the helper and the
Tor switch stays off.

Extension → helper:

| type | payload |
|---|---|
| `tor.start` | `{ bridge: { kind: 'none' \| 'snowflake' \| 'obfs4' \| 'webtunnel', lines?: string[] } }` |
| `tor.stop` | — |
| `tor.newCircuit` | `{ site }` — new isolation token for that site (`default` in Chrome) |
| `bridges.fetch` | `{ kind: 'obfs4' \| 'webtunnel' }` → reply `{ lines }` |
| `torrent.add` | `{ magnet } \| { torrentFile: base64 }` → reply `{ id, name, size }` |
| `torrent.pause` / `torrent.resume` | `{ id }` |
| `torrent.remove` | `{ id, deleteFiles }` |

Helper → extension (events):

| type | payload |
|---|---|
| `tor.status` | `{ phase: 'bridge' \| 'directory' \| 'circuit' \| 'ready', percent }` |
| `tor.ready` | `{ socksPort }` |
| `circuit` | `{ site, bridge?: { kind }, hops: [{ role: 'guard' \| 'bridge' \| 'middle' \| 'exit', nickname, country }] }` |
| `torrent.progress` | `{ id, done, size, downRate, upRate, peers, state }` |
| `error` | `{ code, message, torrentId? }` |

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
  `chrome.proxy.settings.set({ scope: 'incognito_session_only' })` with a
  fixed SOCKS5 server, and `webRTCIPHandlingPolicy = disable_non_proxied_udp`.
  The extension needs "Allow in Incognito"; until it has it, the popup explains
  how to grant it. One circuit for everything; the popup says protection is
  weaker than in Firefox. Regular windows are untouched.
- **New circuit** sends `tor.newCircuit` for the active tab's site.

### Popup (two tabs)

- Top: the Nomada-style segmented switch **Direct / Tor**.
- **Route** tab: the metro diagram for the active tab's site — You → bridge or
  guard → middle → exit → site. Stations carry country flags (Twemoji font, as
  in Nomada). The bridge station's shape and the line segment it covers show
  the transport: dotted for Snowflake, wavy for obfs4, tube for WebTunnel.
  When the circuit changes, stations slide to their new places. Below: the
  bridge picker (opens the bridge list with a mini diagram per type), **New
  circuit**, and the exit IP sites see.
- While connecting, the same line lights up station by station from
  `tor.status` phases, with a percentage and **Cancel**.
- **Downloads** tab (badge shows active count): one row per torrent with
  name, progress bar, speed and state, pause/resume/remove, and the
  "from your IP" warning.
- Light and dark themes from the shared tokens, picked as in Nomada.

### Starting a download

- A content script catches clicks on `magnet:` links and links to `.torrent`
  files.
- Context menu on links: **Download with Tortuga**.
- Paste field on the Downloads tab (magnet link or `.torrent` file).

Each one opens a small extension window to confirm: name, size, destination,
and the "from your IP, not through Tor" note.

### Settings page

Download folder, bridge lines, helper status and version, theme.

## Errors

The rule from Nomada: nothing leaks, and the popup says why.

- **Helper not installed** (`connectNative` fails): the Tor switch is disabled
  and replaced by **Install helper**, linking to the latest release.
- **Helper outdated:** same, with **Update helper**.
- **Tor not ready after 30 s:** the popup offers another bridge type.
- **Helper dies while Tor is on:** the proxy keeps pointing at the dead port,
  so requests fail instead of going direct. The popup turns red and offers
  **Restart**, which reconnects and starts Tor again.
- **Torrent errors** (no peers, disk full, bad link) show in that download's
  row.

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

- Extension: Chrome Web Store and AMO.
- Helper: GitHub Releases — `.pkg` for macOS (signed and notarized, needs an
  Apple Developer ID), `.msi` for Windows, `.deb` and AppImage for Linux. Each
  installer registers the native messaging host manifest for Chrome and
  Firefox and bundles `lyrebird`.

## Not in the first version

Hosting `.onion` services, streaming video from torrents, seeding ratio
limits, running the helper without the browser, routing torrents through a
proxy or VPN, localization beyond English.
