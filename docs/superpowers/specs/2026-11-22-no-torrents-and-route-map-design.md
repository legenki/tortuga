# Tortuga: no torrents, and a route map — design

Status: approved for planning. Two steps, each its own branch and PR:

1. **Remove torrents** from the helper, the browser extension, the macOS app
   and the docs.
2. **Route map**: a dotted world map in the macOS app's window, with each
   app's route drawn on it; a refreshed menu bar panel.

Step 2 starts after step 1 is merged.

## Goal

Tortuga does one thing: it sends traffic through Tor and shows where it
goes. Torrents, which never went through Tor and exposed the user's IP to
the swarm, are gone everywhere. The macOS window shows the routes on a map,
so the user sees at a glance which countries each app's traffic crosses.

## Decisions

| Question | Decision |
|---|---|
| Torrents | Removed from every part, not hidden |
| Map style | Land as a grid of dots; routes drawn over it |
| Window layout | Sidebar stays; on the Route screen the map is on top, the app list under it |
| Menu bar panel | No map; same layout as now (metro line), with app colours and an app count |
| Where the Mac is on the map | The country of the macOS region (`Locale.current.region`); no region, no Mac dot |
| Where a relay is on the map | Its country's label point: Tor only tells us the country |
| Map data | Generated once from Natural Earth by a script, committed as a JSON resource |
| Map tiles from a service (MapKit) | No: in Direct mode tiles would be fetched outside Tor |
| Zoom and pan | No: the map fits itself to the routes |

## Step 1: remove torrents

### Helper (Rust)

- Delete `torrents.rs` and the `librqbit` dependency, and every dependency
  only it needed (check with `cargo tree` after removal; update
  `Cargo.lock`).
- `protocol.rs`: remove the `torrent.*` requests (`torrent.inspect`,
  `torrent.add`, `torrent.open`, `torrent.pause`, `torrent.resume`,
  `torrent.remove`), the `torrent.info` and `torrent.progress` messages,
  the `TorrentFailed` error, and the `.torrent` fetch through Tor.
  `FEATURES` becomes `["apps"]`. The protocol number stays 1: an old
  extension asks for torrents only when the feature is listed.
- `app.rs`, `config.rs`, `main.rs`: remove the torrent session, the
  downloads folder setting and anything else that exists only for torrents.
- Remove `helper/scripts/torrent_check.py`, and torrent steps from
  the package description in `build-deb.sh`.
- An unknown `torrent.*` request from an old extension gets the ordinary
  "unknown request" error.

### Browser extension

- Remove torrent and magnet link handling (`content/links.ts`,
  `lib/torrent-route.ts`), the confirm page (`src/confirm/`), downloads in
  the background and popup (`background/downloads.ts`, `lib/downloads.ts`,
  `popup/downloads.ts`), the torrent options, the torrent messages in
  `lib/messages.ts`, `lib/protocol.ts` and `lib/senders.ts`, and their
  tests and live-check pages.
- Manifests (Chrome and Firefox): drop permissions, content scripts and
  pages used only for downloads; the description loses "and downloads
  torrents".
- Compatibility: the new extension with an old helper works (it never asks
  for torrents). An old extension with the new helper still shows its torrent
  UI; the new helper answers its torrent requests with "Torrent downloads
  were removed in Tortuga 0.3.0. Update the Tortuga extension."

### macOS app

- Remove `DownloadsView`, the Downloads sidebar section, `Download`,
  `DownloadState`, `DownloadSource`, `EngineState.downloads` and
  `downloadsAvailable`, the four download commands of `TortugaEngine`, and
  their implementations in `DemoEngine` and `ProxyEngine`
  (`downloadsLater`), with their tests and previews.

### Docs

- `README.md`, `PRIVACY.md`, `.github/release-notes.md`,
  `extension/BUILD.md`, `store-assets/src/slides.html`: remove torrents,
  including "Torrents don't go through Tor".
- Old specs and plans in `docs/superpowers` stay as they are: they record
  what was decided then.

### Checks

`cargo test` and `cargo clippy` for the helper; `npm test`, type check and
build for the extension; `swift test` for the packages and the app build.
CI green on all platforms.

## Step 2: route map

### Map data

- A script in `macos/tools/map-data/` (Node, dependencies pinned in its
  `package.json` and lockfile) reads two Natural Earth datasets (public
  domain):
  - land at 1:110m, sampled on a 2° grid: a point is kept when it is on
    land;
  - admin-0 countries at 1:50m: for each country its ISO 3166 alpha-2 code
    (`ISO_A2_EH`) and label point (`LABEL_X`, `LABEL_Y`). Label points sit
    inside the main landmass (France's isn't pulled toward French Guiana),
    and 1:50m includes small countries where exits often are, like
    Luxembourg, Monaco and Singapore.
- Output: `WorldMap.json` in the TortugaKit resources:
  `{ "dots": [[lon, lat], …], "countries": { "DE": [lon, lat], … } }`,
  about 50 KB. Committed; the script runs again only to update the data.
- The data's source and licence are noted in the script's README.

### Logic (TortugaKit, no UI, unit-tested)

- **`WorldMap`**: loads `WorldMap.json` from the bundle once.
  `place(country:) -> Coordinate?` takes a code in any case; an unknown
  code gives nil. `dots` is the land grid. If the resource is missing or
  unreadable, `WorldMap` is empty (no dots, no countries) rather than
  crashing; a test makes sure the real resource loads.
- **`MapProjection`**: equirectangular. Built from a set of coordinates and
  a view size with padding, it fits them, keeping at least 40° of
  longitude (and the matching latitude for the view's aspect) so a route
  inside one region isn't blown up. With no coordinates it shows the whole
  world. Maps coordinates to points and back. Routes don't cross the
  antimeridian specially: a line from Europe to Japan goes across the map
  the long way, as on any flat map.
- **`AppColor`**: a stable colour per app, picked from a fixed palette of
  about eight colours by a hash of the app's identifier (a stable hash,
  not Swift's seeded `hashValue`).
- **Spreading exits**: when several apps' exits (or middles) land on the
  same country, each gets a small offset of a few points, the same every
  time for the same app, so the dots don't sit on top of each other.
- **`MapRoute`**: builds what to draw from `EngineState` and the Mac's
  region: the trunk (Mac → bridge/guard) and each app's tail (guard →
  middle → exit), skipping nodes whose country is unknown (the line then
  runs from the previous known node).

### `RouteMap` view (TortugaUI)

- A SwiftUI `Canvas`: land dots in a muted grey, then the trunk, then the
  apps' tails.
  - Trunk: Mac → guard in the route green; with a bridge, in the bridge
    blue, dashed for Snowflake, as the metro line draws it now.
  - Each app: guard → middle → exit in the app's colour, as gently curved
    lines; the exit a filled dot in that colour, the middle a ring.
  - The Mac a white ring; the guard a green ring.
- The Mac is placed at its region's country. No region: no Mac dot, and the
  route starts at the guard.
- While Tor isn't on (connecting, blocked, failed) the lines are grey, as
  the metro line does now. In Direct there are no routes: just the map.
- Excepted apps aren't drawn.
- Highlight: the app whose row is hovered or expanded is drawn at full
  opacity, the others at 30%. With none, all are full.
- Clicking an app's exit dot expands that app's row.
- Accessibility: one element with a label naming each app's route by
  country, like "Safari: Germany, France, Sweden".

### Main window

- Sidebar: Route, Bridges, Exceptions.
- Route screen, top to bottom:
  - the status line, as now;
  - the map, full width, about 240 points high, in a glass card;
  - one line about the shared part: "Guard 🇩🇪 Germany · via Snowflake"
    (replacing today's trunk metro-line card);
  - the app list. A row: a dot in the app's colour, icon, name,
    "🇫🇷 → 🇸🇪", connection count. Expanded, as now: the metro line, the
    exit address, New circuit and Exclude from Tor. Idle apps folded under
    "Idle", excepted apps last, as now.
- Bridges, Exceptions and Settings don't change.

### Menu bar panel

- Same layout as now: Tortuga and the mode switch, the status line, the
  front app with its metro line and exit, the buttons.
- New: a dot in the app's colour before its name; the status says how many
  apps are going through Tor ("Tor on · 3 apps").

### Checks

- Unit tests: `WorldMap` (known codes found in any case, unknown is nil,
  dots not empty, resource present), `MapProjection` (fits the points with
  padding, minimum span, whole world when empty, round trip), `AppColor`
  (same app, same colour across runs), exit spreading (deterministic, no
  two exits on the same point), `MapRoute` (unknown country skipped, no
  region means no Mac, excepted apps left out).
- UI tests: Downloads checks removed; the Route screen has the map, and its
  accessibility label names the countries of the demo routes.
- Previews on DemoEngine: many apps, Tor dies (grey lines), Snowflake
  bridge.
- A live check on the user's Mac with real Tor.

## Out of scope

- Signing with Developer ID and notarising the app, and the Mac App Store.
- Real relay locations (cities); Tor reports countries only.
- Zoom, pan, a globe, or a map in the menu bar panel.
