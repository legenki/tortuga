# Tortuga for macOS — design

Status: part 1 approved for planning. Parts 2–4 are outlined here so part 1
fits them; each gets its own spec before it starts.

## Goal

A native macOS app that sends the whole Mac through Tor, with a separate
circuit for each app, apps that can be left out, bridges, and the torrent
downloads and browser-extension helper that the `.pkg` installs today. It
looks like a macOS 26+ app: Liquid Glass surfaces and capsule controls.

What it says about itself, everywhere it describes itself: **Hides your IP.
Not Tor Browser.** Sending every app through Tor hides the Mac's IP address;
it does not make anyone anonymous. Apps where you are signed in (iCloud,
Telegram, mail) still say who you are.

## Decisions

| Question | Decision |
|---|---|
| What the app does | Tor for the whole Mac, not only the browser |
| Capturing traffic | `NETransparentProxyProvider` in a system extension |
| Distribution | Developer ID, outside the Mac App Store |
| Order | 1 interface on a stand-in engine → 2 core → 3 system Tor → 4 torrents and extension |
| Shape | Menu bar item plus a window with a sidebar |
| Route screen | One shared trunk, then a row per app |
| Languages | English only; strings in a String Catalog so others can be added |
| Minimum macOS | 26 (Liquid Glass); macOS 27 APIs only behind `#available` |

### Why a transparent proxy

- **`NETransparentProxyProvider` (chosen).** macOS hands the extension each
  TCP and UDP flow with the app's signing identifier
  (`NEFlowMetaData.sourceAppSigningIdentifier`) and, when the app connected
  by name, the host name (`NEAppProxyFlow.remoteHostname`). Both are in the
  macOS 27.2 SDK. No user-space TCP stack is needed, and per-app circuits and
  exceptions come straight from the flow.
- **`NEPacketTunnelProvider` (rejected).** It catches everything down to
  ICMP, but needs a user-space TCP/IP stack, and packets don't say which app
  sent them, so there would be no per-app circuits or exceptions.
- **System SOCKS proxy setting (rejected).** Many apps ignore it and reach the
  network directly.

## Architecture (all parts)

```
Tortuga.app (SwiftUI, macOS 26+)
├─ MenuBarExtra ─┐
├─ Window ───────┼─ TortugaUI (views) ─ TortugaKit: models + TortugaEngine protocol
│                │                         ├─ DemoEngine      part 1
│                │                         ├─ ProxyEngine     part 3, XPC to the extension
│                │                         └─ downloads       part 4
├─ Contents/Library/SystemExtensions/TortugaProxy.systemextension   part 3
│     NETransparentProxyProvider + tortuga-core (Arti)
└─ Contents/Helpers/tortuga-helper                                   part 4
      today's helper for the Chrome/Firefox extension, left out of the proxy
```

- **Part 2, `tortuga-core`.** The helper's Rust code (Arti client, bridges and
  Moat, isolation, hop roles, torrents) becomes a library with a Swift
  interface through UniFFI. The helper binary keeps working on top of it, so
  the browser extension does not change.
- **Part 3, system Tor.** The system extension runs `tortuga-core`:
  - Each TCP flow goes to Arti, isolated by the app's signing identifier.
  - UDP port 53 is answered with Tor's resolver.
  - Every other UDP flow, QUIC included, is closed, so apps fall back to TCP.
  - While Tor isn't ready, every flow is closed. Nothing goes out directly
    except apps the user excepted.
  - The app talks to the extension over XPC.
- **Part 4, torrents and the browser extension.** The app runs downloads
  through the core and ships the helper inside its bundle. The app registers
  the helper's native-messaging manifests in the user's Library (as the
  per-user `.pkg` does today). The helper's own traffic is left out of the
  transparent proxy, so there is no Tor over Tor.

## Part 1: the interface on a stand-in engine

The whole app runs and can be clicked through, with no Tor, network or system
extension. Every later part plugs into the protocol defined here.

### Layout

```
macos/
  project.yml             XcodeGen spec; Tortuga.xcodeproj is generated, not committed
  Local.xcconfig.example  DEVELOPMENT_TEAM etc.; copied to Local.xcconfig (ignored)
  Tortuga/                app target: TortugaApp.swift, menu bar, window, Assets, Info.plist
  Packages/TortugaKit/    Swift package, no UI: models, TortugaEngine, DemoEngine
  Packages/TortugaUI/     Swift package: screens and parts (metro line, capsules, app rows)
  TortugaAppUITests/      XCUITest target
  Config/Base.xcconfig    signing defaults; includes Local.xcconfig when present
```

`xcodegen generate` (in `macos/`) writes the project. Logic and views live in
Swift packages, so `swift test` runs their tests without Xcode.

### `TortugaEngine`

```swift
public protocol TortugaEngine: AnyObject, Sendable {
    func states() async -> AsyncStream<EngineState>   // current state first, then every change
    func setMode(_ mode: Mode) async throws
    func restart() async throws
    func newCircuit(for app: AppID?) async throws  // nil: every app
    func selectBridge(_ kind: BridgeKind?) async throws   // nil: no bridge
    func saveBridgeLines(_ lines: [String], for kind: BridgeKind) async throws
    func fetchBridgeLines(_ kind: BridgeKind) async throws -> [String]   // Moat
    func addException(_ app: AppID) async throws
    func removeException(_ app: AppID) async throws
    func pauseDownload(_ id: Download.ID) async throws
    func resumeDownload(_ id: Download.ID) async throws
    func removeDownload(_ id: Download.ID) async throws
    func addDownload(_ source: DownloadSource) async throws               // magnet or .torrent file
}
```

Models (all `Sendable`, `Equatable`):

- `EngineState`: `mode`, `status`, `trunk`, `apps: [AppRoute]`,
  `bridges: BridgeSettings`, `exceptions: [AppID]`, `downloads: [Download]`.
- `Mode`: `.direct`, `.tor`.
- `Status`: `.off`, `.starting(step: String, progress: Double)`, `.on`,
  `.blocked(reason: String)` (Tor stopped and traffic is held back),
  `.failed(reason: String)` (Tor could not start).
- `Trunk`: `bridge: BridgeKind?`, `guardRelay: Relay?` (`guard` is a Swift keyword).
- `AppRoute`: `app: AppID`, `middle: Relay`, `exit: Relay`,
  `connections: Int`, `lastActive: Date`.
- `Relay`: `nickname: String`, `country: String` (ISO code), `address: String`.
- `AppID`: the signing identifier (for example `com.apple.Safari`), plus an
  optional bundle path for apps the system cannot find by identifier, and an
  optional display name used when the app isn't installed. The UI
  looks up the name and icon with `NSWorkspace`; the engine sends only the ID.
- `BridgeKind`: `.snowflake`, `.obfs4`, `.webtunnel`.
  `BridgeSettings`: the selected kind (`nil` = none) and saved lines for each
  kind.
- `Download`: `id`, `name`, `size`, `done` (0…1), `downRate`, `upRate`,
  `state` (downloading, sharing, paused, done, failed), `error`.

The shape follows the helper's protocol (status, hops, bridges, downloads),
with routes per app instead of per site.

`BridgeLines.validate(_:for:)` lives in `TortugaKit`: the same rules as the
extension's `isBridgeAddr` check, so the Bridges screen marks bad lines as
they are typed.

### Screens

**Menu bar item.** A `MenuBarExtra` with the window style:

- **Top:** "Tortuga" and a Direct / Tor capsule switch.
- **Status line:** a coloured dot, then "Tor on via Snowflake",
  "Connecting… 45%" or "Tor stopped — traffic is blocked".
- **Front app's route:** the app in front (from
  `NSWorkspace.frontmostApplication`) drawn as a metro line: Mac → bridge →
  guard → middle → exit, with country flags and the exit IP. Before that app
  has a route, it shows "No traffic from <App> yet".
- **Buttons:** capsule `.glass` buttons: "New circuit" (front app),
  "Open Tortuga", "Quit".
- **Icon:** an SF Symbol, in four states:
  - `tortoise.fill` while Tor is on;
  - `tortoise.fill` with a pulse while connecting;
  - `exclamationmark.triangle.fill` while blocked or failed;
  - `tortoise` (outlined) in Direct.

**Window.** A `NavigationSplitView` with a glass sidebar. The toolbar holds
the Direct / Tor capsule and the status.

- **Route.**
  - **Trunk:** one metro line at the top for the shared part
    (Mac → bridge → guard).
  - **App rows:** below it, one row per app: icon, name, a short metro line,
    middle → exit flags.
  - **Order:** rows are sorted by last activity. Apps idle for over 10 minutes
    fold into an "Idle" group. Excepted apps sit last, dimmed, marked "direct".
  - **Details:** clicking a row opens the relays with nicknames and addresses,
    the connection count, "New circuit" and "Exclude from Tor".
  - **Empty:** with Tor on and no apps yet, it says "Apps appear here as they
    connect".
- **Bridges.**
  - **Kinds:** cards for None, Snowflake, obfs4 and WebTunnel; selecting one
    applies it.
  - **Lines:** obfs4 and WebTunnel take pasted lines (bad ones marked as
    typed), "Get lines" (Moat) and a saved-lines count.
  - **Errors:** an error from "Get lines" shows under the button.
- **Exceptions.**
  - **The list:** apps that bypass Tor. Add with "+" (choose an `.app`) or
    from a Route row; remove with "−".
  - **Warning:** under the list: "These apps connect directly. Sites they
    reach see your IP address."
- **Downloads.** Rows with name, progress, rates, state, and pause, resume and
  remove. Dropping a `.torrent` file or a magnet link on the window adds one.
  Sharing stops at ratio 1.0, as today.

**Settings window** (⌘,):

- **General:** open at login (`SMAppService.mainApp`) and show in Dock (off by
  default, so the app runs as an accessory).
- **Downloads:** the downloads folder.
- **About:** version, "Hides your IP. Not Tor Browser." and a link to the
  repository.

**First run.** One card with three points:

- what Tortuga does;
- what it doesn't do (apps you're signed in to still say who you are);
- that macOS will ask once to allow its system extension (from part 3).

The card has a "Continue" button. It doesn't come back once dismissed.

**Look.**

- **Glass:** system glass only: `glassEffect`, `GlassEffectContainer`, and the
  `.glass` and `.glassProminent` button styles.
- **Colours:**
  - The only custom colour is the route green, from the extension's
    `--accent`.
  - Snowflake and bridge segments use the extension's blue.
  - Everything else uses system colours, so light, dark and the
    accessibility settings (Reduce Transparency, Increase Contrast) work
    without extra code.
- **Metro line:** one SwiftUI `Shape` view, used in the menu bar, the trunk
  and the rows.

### `DemoEngine`

A `TortugaEngine` that behaves like the real one, without a network.

Its behaviour in the Normal scenario:

- **Connecting:** about four seconds of steps with progress, then `.on`
  through Snowflake.
- **Apps:** they appear one at a time: Safari, Telegram, Slack, Music, and
  Mail as an exception. Countries are drawn from a fixed list of real exit
  countries, using a seeded random generator so previews and tests are stable.
- **New circuit:** after one second it changes the middle and the exit.
- **Bridge lines:** `fetchBridgeLines(.obfs4)` returns seven well-formed lines
  after half a second. `.webtunnel` fails with "none are needed here".
- **Downloads:** progress grows over time, and sharing stops at ratio 1.0.

Scenarios are picked in a Demo tab of Settings (debug builds; the app has no main menu while it runs from the menu bar) or with the
`-scenario <name>` launch argument (used by UI tests):

| Scenario | Behaviour |
|---|---|
| `normal` | as above |
| `slowBootstrap` | connecting takes 30 s |
| `bridgeFails` | Snowflake never connects; status `.failed("Snowflake can't reach its broker")`, pointing to Bridges |
| `torDies` | 5 s after `.on`, status becomes `.blocked("Tor stopped")`; `restart()` brings it back |
| `manyApps` | 30 apps, half of them idle |
| `empty` | Tor on, no apps |

### Errors

- **Where they show:** errors appear where they happened, not in alerts. A
  failed command shows under its control. `.blocked` and `.failed` show in the
  status line, the menu bar and the window toolbar.
- **Next step:** each of them names the next step: Restart, a different
  bridge, or open Bridges.

### Tests

- **`TortugaKit`, with `swift test`:**
  - state changes in each `DemoEngine` scenario (with a clock the test
    controls);
  - bridge line checks;
  - sorting app rows and folding idle ones;
  - adding and removing exceptions.
- **`TortugaUI`:** a preview for every screen in each relevant scenario, light
  and dark.
- **`TortugaUITests` (XCUITest):**
  - Tor on → apps appear → "New circuit" changes an app's exit;
  - `-scenario torDies` → blocked status → Restart → on;
  - adding an exception and removing it;
  - a bad obfs4 line is marked, a good one is saved.

### Build and signing

- **Signing:** Developer ID on the user's team. `DEVELOPMENT_TEAM` comes from
  `macos/Local.xcconfig` (ignored by git; an `.example` file is committed).
- **Entitlements:** hardened runtime on; no entitlements beyond that in
  part 1.
- **CI:** a macOS job runs `xcodegen`, `swift test` for both packages and the
  UI tests.

Notarised builds and release packaging come when there is something to
release (part 3).

### Not in part 1

- Tor, any network access, the system extension, real torrents and the
  bundled helper.
- Any change to the browser extension or to the existing helper.
