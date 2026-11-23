# Tortuga for macOS: a Tor app list, and the map as the window — design

Status: approved for planning. One branch and one PR. Mockup (open in a
browser; clickable): `docs/mockups/map-window.html`.

## Goal

Two changes to the macOS app, made together because the second shows the
first:

1. **Only the listed apps go through Tor.** Today every app goes through
   Tor unless the user excepts it. From now on there is a list of apps that
   go through Tor. It starts with the browsers installed on the Mac, and
   the user adds other apps by hand or removes any of them. Every other app
   connects directly. Exceptions are gone.
2. **The map is the window.** The dotted map fills the whole window, and
   everything else floats over it on glass panels. The sidebar, the
   Direct/Tor switch and the metro-line rows are replaced. The map gets four
   times as many dots.

## Decisions

| Question | Decision |
|---|---|
| What goes through Tor | Only the apps in the list; all others connect directly |
| The list at first | The browsers installed on this Mac (apps that open `https:` links), except Tor Browser and Tortuga |
| A browser installed later | Not added on its own; the user adds it |
| Old exceptions | Dropped. A browser that was excepted is left out of the first list |
| Helper processes (for example `com.google.Chrome.helper`) | Count as the listed app whose ID they extend with a `.`; they share its row and its circuit |
| DNS of unlisted apps | Sent to the system's resolver, not through Tor |
| Unlisted apps while Tor is starting or stopped | Connect directly; only listed apps are held back |
| Apps going direct | Shown under "Going direct" (seen in the last hour), each with a `+` |
| Removing an app | A trash button on the selected row, and `−` on hover |
| Adding an app | "+ Add app…" (a file picker in /Applications), `+` in "Going direct", or "+ Send … through Tor" in the menu |
| Window navigation | A segmented control in the toolbar: Route · Bridges. No sidebar |
| Turning Tor on and off | The status pill on the right of the toolbar is the button |
| Turtle slider (mockup A v1) | Not built |
| Map dots | A 1° grid (15,496 dots) instead of 2° (3,890) |
| Menu bar panel | No "Tortuga" title; the status pill on top; the front app's route as a vertical line |

## Part 1: the Tor app list

### Model (TortugaKit)

- `EngineState.exceptions: [AppID]` is replaced by:
  - `torApps: [AppID]`: the list, in the order the user sees it;
  - `seenDirect: [AppID]`: apps whose connections went direct in the last
    hour, most recent first, never including a listed app.
- `TortugaEngine`: `addException` and `removeException` become
  `addTorApp(_:)` and `removeTorApp(_:)`. Adding an app removes it from
  `seenDirect`.
- `RouteList` becomes the rows of the list:
  - `active`: listed apps with traffic in the last ten minutes, most recent
    first;
  - `idle`: listed apps with older traffic;
  - `waiting`: listed apps that haven't connected yet (no `AppRoute`).

  An `AppRoute` whose app isn't listed (a route left over after removal) is
  not shown and is not drawn on the map.
- `MapRoute` and `RouteSummary` draw and describe only listed apps.

### Which apps count (TortugaProxyKit)

`TorAppMatcher.match(_ signingID: String, in list: Set<String>) -> String?`
returns the listed ID that the signing identifier belongs to:

- `id` itself when it's listed;
- else the longest listed `id` such that `signingID` starts with `id + "."`
  (so `com.google.Chrome.helper` → `com.google.Chrome`);
- else nil.

`TorAppMatcher.match(lineage: [String], in:) -> String?` returns the match
for the first element of a process's lineage (the process itself, then its
parent, grandparent, … up to launchd) that matches. An app's child
processes, found through the process tree, count as that app, not only its
`.`-prefixed helpers: Firefox's WebRTC runs in `org.mozilla.plugincontainer`
(no prefix match; its UDP went out directly and leaked the Mac's address),
and `curl` run from a listed Terminal reports `com.apple.curl`. Both now
count as the listed ancestor, which is also their isolation. `FlowInfo`
carries the ancestors lazily (`ancestors: () -> [String]`), consulted only
when the process itself doesn't match, and `DNSRoute.upstream` takes the
same lineage. The extension finds it from the flow's audit token (pid, then
`sysctl` `KERN_PROC_PID` for each parent, and each ancestor's signing ID
from Security), at most 16 hops, cached for 30 s. Processes launchd starts
for an app (XPC services) aren't its children and count only by their own ID.

### Routing a connection

`RouterState.exceptions` becomes `torApps: Set<String>`.
`FlowRouter.decide` becomes, in order:

1. Our own programs (helper, lyrebird), or a local address → `.direct`.
2. `TorAppMatcher.match` gives nil, for the process and its ancestors → `.direct`, and the engine records the
   flow's app in `seenDirect` (below).
3. UDP, or Tor not ready → `.refuse` (as today, but now only for listed
   apps).
4. Otherwise → `.tor(host:, port:, isolation: matchedID)`. The isolation is
   the listed ID, not the helper's, so an app and its helpers share one
   circuit and one row.

### DNS

`DNSProxy` already sends our own programs' queries to the system's
resolver. Unlisted apps' queries go the same way: the upstream is chosen
by a pure function `DNSRoute.upstream(app:torApps:own:system:)` that
returns the system server for own or unlisted apps, and nil (answer
through Tor) for listed apps. A DNS flow can't be passed back to macOS
(returning false drops it; spike Q6), so this forwarding is required, not
optional.

### Recording "Going direct"

- `ProxyCore` keeps `[signingID: lastSeen]` for flows decided `.direct` in
  step 2, at most 200 entries (oldest dropped), entries older than an hour
  dropped. It is sent with the rest of the state over XPC.
- The extension records signing IDs only. The app shows only those that
  `NSWorkspace.urlForApplication(withBundleIdentifier:)` finds as a `.app`
  bundle. Daemons such as `com.apple.mDNSResponder` are never shown.
- Not stored on disk: after a restart the section starts empty.

### Settings and the first list

- `StoredSettings.exceptions` is replaced by `torApps: [AppID]?`. nil means
  never set.
- When `ProxyEngine` loads settings with `torApps == nil`, it fills the list
  from an injected `installedBrowsers: () -> [AppID]` and saves it. Old
  `exceptions` in the stored JSON are read once, only to leave those apps
  out, and are not written back. Decoding must accept the old JSON (with
  `exceptions`, without `torApps`).
- `installedBrowsers` (in the app target, using AppKit):
  - `NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)`;
  - each URL's bundle identifier;
  - minus `org.torproject.torbrowser`, Tortuga itself, and copies on
    mounted disk images or in build folders (paths under `/Volumes/`, or
    containing `/DerivedData/` or `/Build/Products/`);
  - deduplicated, sorted by name.
- `ProxyConfiguration.exceptions` becomes `torApps: [String]` (IDs). The
  XPC message keeps its name. The extension and the app ship together, so
  no compatibility with the old message is needed.

### Errors

- "+ Add app…" on a bundle without an identifier → the existing error text
  under the list: "Tortuga can't route <name>: it has no bundle identifier."
- Adding an app already listed → no-op (the row gets selected).
- Removing the last app is allowed. The list then shows "No apps go
  through Tor. Add one with + Add app…".

## Part 2: the window

### Layout

```
┌───────────────────────────────────────────────────────────────┐
│ ● ● ●            [ Route | Bridges ]       (● Tor on · 3 apps │
│                                              · Guard 🇩🇪 …  ⏻) │
│ ┌──────────────┐                                              │
│ │ THROUGH TOR  │        · · · dotted map, full window · · ·   │
│ │ ● Safari 🇫🇷→🇸🇪│                 ╭──────● 🇸🇪 Sweden          │
│ │   Mac        │           Guard ●╯                           │
│ │   Guard 🇩🇪   │              ╰─● Mac                         │
│ │   Middle 🇫🇷  │                                              │
│ │   Exit 🇸🇪 IP │                                              │
│ │  [↻ New circuit] [🗑]                                        │
│ │ ● Firefox    │                                              │
│ │ ○ Chrome idle│                                              │
│ │ + Add app…   │                                              │
│ │ GOING DIRECT │                                              │
│ │ # Slack   (+)│                                              │
│ └──────────────┘                                              │
└───────────────────────────────────────────────────────────────┘
```

- `MainWindow` drops `NavigationSplitView`. It is one view: the map behind
  everything (under the toolbar too), and the toolbar on top with:
  - `.principal`: a segmented `Picker` (Route, Bridges), bound to
    `model.section` (`SidebarSection` loses `.exceptions` and is renamed
    `WindowSection`);
  - `.primaryAction`: `StatusPill(showsGuard: true)`.
- Minimum size stays 700 × 640.

### Status pill (replaces ModeSwitch and StatusLine)

A glass capsule button. What it shows, and what a click does:

| Status | Shows | Click |
|---|---|---|
| off | ○ **Direct** · turn on Tor | `setMode(.tor)` |
| starting | ● **Connecting… 42%** · step, with the capsule filled to the progress in the caution colour | `setMode(.direct)` |
| on | ● **Tor on** · N apps · Guard 🇩🇪 Germany (guard part only in the window) | `setMode(.direct)` |
| blocked | ● (red) **Tor stopped** · Tor apps are blocked | `setMode(.direct)` |
| failed | ● (red) the reason | `setMode(.direct)` |

- N counts active listed apps. The `⏻` glyph after the text marks the pill
  as a button. Accessibility: label = the text, the button trait, hint
  "Turns Tor on" / "Turns Tor off", identifier `status`.
- Blocked and failed also show a **problem banner**: a glass card at the
  top centre of the map, below the toolbar, with the reason and the
  buttons today's StatusLine has (Restart; Open System Settings for the
  extension reason; Bridges… for failed, which switches to the Bridges
  section). Mode and restart errors show in red in the same banner.
- `Status.text` for blocked changes from "<reason> — traffic is blocked" to
  "<reason> — Tor apps are blocked", since unlisted apps keep working.

### The Route section

- **The app panel**: glass, floating on the left, 12 pt from the edges,
  288 pt wide, full height under the toolbar, scrolling inside. Its
  sections:
  - **THROUGH TOR**: active, then idle (dimmed, "idle" tag), then waiting
    ("no traffic yet"). A row has: the app colour dot (grey when not lit),
    icon, name, `🇫🇷 → 🇸🇪`, and a `−` button on hover
    (`remove.<id>`).
  - Click a row to select it (`model.expandedApp`, as now). The map flies to
    it, and the row opens a **vertical route**: Mac · Guard 🇩🇪 country ·
    Middle 🇫🇷 nickname · Exit 🇸🇪 address, the trunk stations green and the
    app's own in its colour; "N connections"; then **↻ New circuit** and a
    **trash** button (SF Symbol `trash`, help text and accessibility label
    "Remove from Tortuga", red on hover, identifier `trash.<id>`).
  - **+ Add app…** (dashed button, `add.app`): `NSOpenPanel` in
    /Applications, `.application` only, one app; then
    `AppInfo.id(forAppAt:)`.
  - **GOING DIRECT · seen in the last hour**: dimmed rows with a `+`
    (`add.<id>`). Hidden when empty.
  - The context menu on a listed row: New circuit, Remove from Tortuga.
- **The map** fills the window. `RouteMap` gets an `insets: EdgeInsets`
  parameter (leading = panel width + 24, top = toolbar height + 12), and
  `MapProjection` fits the camera into the rectangle left by the insets
  instead of the whole size with one padding. Everything else from the
  route-map work stays: fly-to on selection, log-space zoom, hover
  highlight, exit-dot clicks, Reduce Motion jumps.
- **New on the map** (off under Reduce Motion):
  - traffic flow: a light dashed stroke over the trunk and over the
    selected (or hovered) app's tail, its dash phase animated (about 12 pt
    per second);
  - the exit dot of an active app pulses, faster the more connections it
    has (period from 3.2 s at 0 down to 1.0 s at 12 or more);
  - the selected app's exit is labelled "🇸🇪 Sweden".
- The guard line under the map ("Guard 🇩🇪 Germany · via …") moves into the
  status pill and the vertical route; the separate text is removed.

### The Bridges section

Today's `BridgesView` content, unchanged, inside a centred glass card
(480 pt wide) over the map. The land dims and no routes are drawn while it
shows. The app panel is hidden.

### The map data: 4× dots

- `make-map-data.mjs`: `STEP = 1`. Regenerate `WorldMap.json` (15,496 dots,
  about 200 KB). `WorldMapTests` update their dot-count bounds.
- The land dot radius follows the zoom: `clamp(0.3 × points per degree,
  0.85, 3.2)`.
- `LandCache` adds only dots inside the visible rectangle (plus a dot's
  radius) to the path, so a zoomed-in flight builds fewer ellipses. Check
  with Instruments that a flight keeps 60 fps on this Mac. If it doesn't,
  the plan's fallback: draw the land into a cached image per projection
  only when the camera is still, and draw the dots without culling while
  it flies.

## Part 3: the menu bar panel

- No "Tortuga" title. On top: `StatusPill(showsGuard: false)`, full width.
- The front app's card:
  - listed and routed: icon, name, "N conn.", then the vertical route;
  - listed, no traffic yet: "No traffic from <name> yet.";
  - not listed: "<name> connects directly: it isn't in Tortuga." and a
    button **+ Send <name> through Tor** (`menu.add`).
- Buttons: ↻ New circuit (disabled unless the front app is routed), Open
  Tortuga, Quit.

## What is removed

`ExceptionsView`, `ModeSwitch`, `StatusLine`, `MetroLine` (its stop
building moves to the vertical route view), `AppRow`, `ExceptedRow`, the
sidebar, `RouteList.excepted`, the exception commands, `.exceptions` in
`AppModel`'s error keys (now `.apps`).

## The demo engine

`DemoEngine` (used by previews and UI tests) follows the new model:
`torApps` = Safari, Firefox, Chrome (listed, never connects: waiting), Telegram; `seenDirect` = Slack,
Music; adding and removing work. Unlisted apps never get routes.

## Testing

Unit tests (Swift Testing), all in the existing packages:

- `TorAppMatcher`: exact, helper prefix, longest prefix wins, no match,
  `com.google.ChromeX` doesn't match `com.google.Chrome`.
- `FlowRouter`: listed → tor with the listed ID as isolation; helper → tor
  with the parent's isolation; unlisted → direct even when Tor isn't
  ready; listed while Tor isn't ready → refuse; own and local → direct.
- `DNSRoute.upstream`: own and unlisted → system; listed → nil.
- `ProxyCore`'s direct record: added, refreshed, aged out after an hour,
  capped at 200.
- `ProxyEngine`: first load seeds from `installedBrowsers` minus old
  exceptions; old JSON decodes; add/remove persist; adding removes from
  `seenDirect`; `ProxyConfiguration` carries `torApps`.
- `installedBrowsers` filtering, with an injected list of URLs.
- `RouteList`: active / idle / waiting; unlisted routes dropped.
- `StatusPill` text and click action per status (a pure
  `StatusPill.Content(state:showsGuard:)`).
- `MapProjection` with insets; `WorldMap` dot count.

UI tests (`TortugaAppUITests`), updated to the new identifiers:

- Tor on via the pill (`status`), apps appear, New circuit changes the
  exit (as now).
- Remove an app with the trash button: it leaves the list and shows under
  Going direct; `+` brings it back.
- The map exists (`route.map`) and the Bridges segment shows the bridge
  settings (`bridge.obfs4` reachable).
- Tor dies → the banner offers Restart (as now, with the new status text).
- The obfs4 test stays as it is.

Live check on this Mac (after `install-dev.sh`), recorded in the PR:

- Safari, Firefox and Chrome are in the list on first launch.
  `https://check.torproject.org` says "Congratulations" in each.
- `curl https://check.torproject.org/api/ip` from Terminal (unlisted) shows
  the real IP. After adding Terminal, the same command shows a Tor IP.
- Chrome's traffic shows as one row, Chrome, not "Google Chrome Helper".
  If the log shows another helper ID pattern, the matcher is extended in
  the same PR.
- While Tor starts, an unlisted app loads pages; a listed one waits.

## Out of scope

- Redesigning the Bridges settings themselves.
- A per-app "always direct" for listed-app helpers.
- Remembering "Going direct" across restarts.
- The browser extension and the helper: unchanged.
