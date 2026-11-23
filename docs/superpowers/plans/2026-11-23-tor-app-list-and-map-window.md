# Tor App List and Map Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only the apps in a list (browsers at first) go through Tor, and the macOS window becomes a full-window dotted map with glass panels over it.

**Architecture:** The list replaces exceptions end to end: `EngineState.torApps` in the model, `StoredSettings.torApps` (seeded with installed browsers) in the app, `ProxyConfiguration.torApps` over XPC, and `FlowRouter`/`DNSRoute` in the extension, which send unlisted apps directly and record them for "Going direct". The UI drops the sidebar: a `ZStack` with `RouteMap` behind, an `AppPanel` on the left, a `SectionSwitch` and a `StatusPill` in the toolbar.

**Tech Stack:** Swift 6, SwiftUI (macOS 26, Liquid Glass), Swift Testing, NetworkExtension, XCUITest, Node + d3-geo (map data).

**Spec:** `docs/superpowers/specs/2026-11-23-tor-app-list-and-map-window-design.md`. **Mockup:** `docs/mockups/map-window.html`.

**Branch:** `design/allowlist-redesign` (already holds the spec). Don't push until the user asks.

**Test commands** (run from the repository root):

- `cd macos/Packages/TortugaKit && swift test`
- `cd macos/Packages/TortugaProxyKit && swift test`
- `cd macos/Packages/TortugaUI && swift test`
- `cd macos && xcodegen && xcodebuild -scheme Tortuga -destination 'platform=macOS' build-for-testing` (expect `** TEST BUILD SUCCEEDED **`)

UI tests drive the user's screen: never run them without asking the user first.

Commits end with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

## File map

TortugaKit (`macos/Packages/TortugaKit/Sources/TortugaKit/`):

- Create `TorAppMatcher.swift`: which listed app a signing identifier belongs to.
- Modify `Models.swift` (`EngineState`), `TortugaEngine.swift`, `RouteList.swift`, `MapRoute.swift`, `DemoEngine.swift`, `DemoData.swift`, `MapProjection.swift` (insets, `dotRadius`).
- Regenerate `Resources/WorldMap.json` (1° grid).

TortugaProxyKit (`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/`):

- Create `InstalledBrowsers.swift`, `DNSRoute.swift`.
- Modify `Settings.swift`, `ProxyEngine.swift`, `ProxyMessages.swift`, `FlowRouter.swift`, `RouteTable.swift`, `ProxyCore.swift`.

Extension (`macos/TortugaProxy/`): modify `TransparentProxy.swift`, `DNSProxy.swift`.

App (`macos/Tortuga/TortugaApp.swift`, `macos/project.yml`).

TortugaUI (`macos/Packages/TortugaUI/Sources/TortugaUI/`):

- Create `StatusPill.swift`, `ProblemBanner.swift`, `VerticalRoute.swift`, `AppPanel.swift`, `SectionSwitch.swift`.
- Modify `MainWindow.swift`, `AppModel.swift`, `AppInfo.swift`, `RouteMap.swift`, `RouteSummary.swift`, `MenuPanel.swift`, `Theme.swift`, `FirstRunView.swift`, `Previews.swift`, `BridgesView.swift`.
- Delete `ExceptionsView.swift`, `ModeSwitch.swift`, `StatusLine.swift`, `MetroLine.swift`, `RouteView.swift`.

Tests: the matching `Tests/` folders, and `macos/TortugaAppUITests/TortugaAppUITests.swift`.

---

### Task 1: TorAppMatcher

**Files:**
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/TorAppMatcher.swift`
- Test: `macos/Packages/TortugaKit/Tests/TortugaKitTests/TorAppMatcherTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import TortugaKit

private let list: Set<String> = ["com.google.Chrome", "com.apple.Safari", "com.google", "org.mozilla.firefox"]

@Test func aListedAppMatchesItself() {
    #expect(TorAppMatcher.match("com.apple.Safari", in: list) == "com.apple.Safari")
}

@Test func aHelperMatchesItsApp() {
    #expect(TorAppMatcher.match("com.google.Chrome.helper", in: list) == "com.google.Chrome")
    #expect(TorAppMatcher.match("com.google.Chrome.helper.Renderer", in: list) == "com.google.Chrome")
}

@Test func theLongestPrefixWins() {
    #expect(TorAppMatcher.match("com.google.Chrome.helper", in: list) != "com.google")
    #expect(TorAppMatcher.match("com.google.Drive", in: list) == "com.google")
}

@Test func onlyWholeComponentsMatch() {
    #expect(TorAppMatcher.match("com.google.ChromeX", in: ["com.google.Chrome"]) == nil)
    #expect(TorAppMatcher.match("com.apple.mail", in: list) == nil)
    #expect(TorAppMatcher.match("", in: list) == nil)
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd macos/Packages/TortugaKit && swift test --filter TorAppMatcher`
Expected: build error, `cannot find 'TorAppMatcher' in scope`.

- [ ] **Step 3: Implement**

```swift
/// Which app in the Tor list a connection belongs to, by the code-signing
/// identifier macOS reports for it.
public enum TorAppMatcher {
    /// The listed identifier itself, or the longest listed one that the
    /// identifier extends with a "." (an app's helper, like
    /// com.google.Chrome.helper for com.google.Chrome); nil when none.
    public static func match(_ signingID: String, in list: Set<String>) -> String? {
        if list.contains(signingID) { return signingID }
        return list
            .filter { signingID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd macos/Packages/TortugaKit && swift test --filter TorAppMatcher`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaKit/Sources/TortugaKit/TorAppMatcher.swift macos/Packages/TortugaKit/Tests/TortugaKitTests/TorAppMatcherTests.swift
git commit -m "feat(macos): TorAppMatcher, which listed app a connection belongs to"
```

---

### Task 2: The model switches from exceptions to a Tor list

This task changes the shared model and protocol, so it also makes the
smallest changes that keep TortugaProxyKit and TortugaUI building. The
window still has its old layout after this task; the Exceptions screen is
deleted.

**Files:**
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/Models.swift` (`EngineState`)
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/TortugaEngine.swift`
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/RouteList.swift`
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/MapRoute.swift:61`
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/DemoEngine.swift`, `DemoData.swift`
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/Settings.swift`, `ProxyEngine.swift`
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/RouteSummary.swift`, `StatusLine.swift`, `MenuPanel.swift`, `RouteView.swift`, `MainWindow.swift`, `AppModel.swift`
- Delete: `macos/Packages/TortugaUI/Sources/TortugaUI/ExceptionsView.swift`
- Test: `TortugaKitTests/RouteListTests.swift`, `MapRouteTests.swift`, `DemoEngineTests.swift`, `DemoEngineCommandTests.swift`, `CodableTests.swift`; `TortugaProxyKitTests/ProxyEngineTests.swift`

- [ ] **Step 1: Rewrite the RouteList tests**

Replace the two tests in `RouteListTests.swift` (keep the helpers above them):

```swift
@Test func sortsByLastActivityAndFoldsIdleApps() {
    let list = RouteList(
        apps: [route("old", secondsAgo: 300), route("new", secondsAgo: 5), route("sleepy", secondsAgo: 601)],
        torApps: [AppID("old"), AppID("new"), AppID("sleepy")],
        now: now
    )
    #expect(list.active.map(\.id) == ["new", "old"])
    #expect(list.idle.map(\.id) == ["sleepy"])
    #expect(list.waiting.isEmpty)
}

@Test func listedAppsWithoutTrafficWait() {
    let list = RouteList(apps: [route("safari", secondsAgo: 2)],
                         torApps: [AppID("safari"), AppID("firefox")], now: now)
    #expect(list.active.map(\.id) == ["safari"])
    #expect(list.waiting == [AppID("firefox")])
}

@Test func routesOfUnlistedAppsAreLeftOut() {
    let list = RouteList(apps: [route("mail", secondsAgo: 1), route("safari", secondsAgo: 2)],
                         torApps: [AppID("safari")], now: now)
    #expect(list.active.map(\.id) == ["safari"])
}
```

- [ ] **Step 2: Update the other TortugaKit tests**

`MapRouteTests.swift`: the `state(...)` helper's parameter `exceptions: [AppID] = []` becomes `unlisted: [AppID] = []`, and its body sets the list to every app except those:

```swift
    s.torApps = apps.map(\.app).filter { !unlisted.contains($0) }
```

(replacing `s.exceptions = exceptions`). At lines 92 and 140 change `exceptions: [AppID("b")]` to `unlisted: [AppID("b")]`.

`CodableTests.swift:15`: `state.exceptions = [AppID("com.apple.mail")]` becomes

```swift
    state.torApps = [AppID("com.apple.Safari")]
    state.seenDirect = [AppID("com.apple.mail")]
```

`DemoEngineTests.swift:17`: `#expect(s.exceptions == [DemoData.mail])` becomes

```swift
        #expect(s.torApps == DemoData.torApps)
        #expect(s.seenDirect == DemoData.direct)
```

`DemoEngineTests.swift:40`: `#expect(await engine.current.apps.count == 4)` becomes `== 3` (Safari, Telegram, Firefox arrive; Chrome is listed but never connects).

`DemoEngineCommandTests.swift`: replace `exceptingAnAppDropsItsRouteAndKeepsItOut` with:

```swift
    @Test func removingAnAppDropsItsRouteAndKeepsItOut() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))   // on
        await engine.advance(by: .seconds(1))   // Safari arrives
        try await engine.removeTorApp(safari)
        #expect(await engine.current.apps.isEmpty)
        #expect(await !engine.current.torApps.contains(safari))
        #expect(await engine.current.seenDirect.first == safari)
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.apps.map(\.app.id) == ["ru.keepcoder.Telegram", "org.mozilla.firefox"])
        try await engine.addTorApp(safari)
        #expect(await engine.current.torApps.last == safari)
        #expect(await !engine.current.seenDirect.contains(safari))
        await engine.advance(by: .seconds(1))
        #expect(await engine.current.apps.contains { $0.app == safari })
    }
```

and in `manyAppsShowsThirtyHalfOfThemIdle`, `RouteList(apps: s.apps, exceptions: s.exceptions, now: …)` becomes `RouteList(apps: s.apps, torApps: s.torApps, now: …)`.

- [ ] **Step 3: Run TortugaKit tests to see them fail**

Run: `cd macos/Packages/TortugaKit && swift test`
Expected: build errors (`torApps`, `seenDirect`, `waiting`, `addTorApp` don't exist).

- [ ] **Step 4: Change the model**

`Models.swift`, in `EngineState`, replace `public var exceptions: [AppID] = []` with:

```swift
    /// The apps that go through Tor, in the order the user sees them.
    public var torApps: [AppID] = []
    /// Apps whose connections went directly in the last hour (they aren't
    /// listed), most recent first.
    public var seenDirect: [AppID] = []
```

`TortugaEngine.swift`, replace the two exception methods with:

```swift
    /// Send an app through Tor from its next connection.
    func addTorApp(_ app: AppID) async throws
    /// The app connects directly again.
    func removeTorApp(_ app: AppID) async throws
```

`RouteList.swift`, whole file:

```swift
import Foundation

/// The Tor list's rows: listed apps with traffic in the last ten minutes
/// (most recent first), listed apps with older traffic, and listed apps that
/// haven't connected yet. Routes of apps no longer listed are left out.
public struct RouteList: Sendable, Equatable {
    public static let idleAfter: TimeInterval = 600

    public var active: [AppRoute]
    public var idle: [AppRoute]
    public var waiting: [AppID]

    public init(apps: [AppRoute], torApps: [AppID], now: Date) {
        let listed = Set(torApps)
        let routed = apps
            .filter { listed.contains($0.app) }
            .sorted { $0.lastActive > $1.lastActive }
        active = routed.filter { now.timeIntervalSince($0.lastActive) <= Self.idleAfter }
        idle = routed.filter { now.timeIntervalSince($0.lastActive) > Self.idleAfter }
        waiting = torApps.filter { app in !apps.contains { $0.app == app } }
    }
}
```

`MapRoute.swift:61`: `.filter { !state.exceptions.contains($0.app) }` becomes `.filter { state.torApps.contains($0.app) }`. Update the type's doc comment: "each listed app's tail".

- [ ] **Step 5: Change the demo engine**

`DemoData.swift`: replace `normalApps` and `mail` with:

```swift
    /// The Tor list in the demo: three browsers and Telegram.
    static let torApps = [
        AppID("com.apple.Safari", name: "Safari"),
        AppID("org.mozilla.firefox", name: "Firefox"),
        AppID("com.google.Chrome", name: "Google Chrome"),
        AppID("ru.keepcoder.Telegram", name: "Telegram"),
    ]

    /// Listed apps that connect one by one in the normal scenario. Chrome
    /// never does: it shows as waiting.
    static let normalApps = [
        AppID("com.apple.Safari", name: "Safari"),
        AppID("ru.keepcoder.Telegram", name: "Telegram"),
        AppID("org.mozilla.firefox", name: "Firefox"),
    ]

    /// Unlisted apps seen going direct in the normal scenario.
    static let direct = [
        AppID("com.tinyspeck.slackmacgap", name: "Slack"),
        AppID("com.apple.Music", name: "Music"),
    ]
```

`DemoEngine.swift`:

- In `init`, replace the `if scenario != .empty && scenario != .manyApps { state.exceptions = [DemoData.mail] }` block with:

```swift
        switch scenario {
        case .empty: break
        case .manyApps: state.torApps = DemoData.manyApps
        default:
            state.torApps = DemoData.torApps
            state.seenDirect = DemoData.direct
        }
```

- Replace `addException` / `removeException` with:

```swift
    public func addTorApp(_ app: AppID) throws {
        if !state.torApps.contains(app) { state.torApps.append(app) }
        state.seenDirect.removeAll { $0 == app }
        if state.status == .on { schedule(.seconds(1), .arrive(app)) }
        publish()
    }

    public func removeTorApp(_ app: AppID) throws {
        state.torApps.removeAll { $0 == app }
        state.apps.removeAll { $0.app == app }
        state.seenDirect.removeAll { $0 == app }
        state.seenDirect.insert(app, at: 0)
        publish()
    }
```

- In `fire(.arrive)`, `!state.exceptions.contains(app)` becomes `state.torApps.contains(app)`.

- [ ] **Step 6: Run TortugaKit tests**

Run: `cd macos/Packages/TortugaKit && swift test`
Expected: all pass.

- [ ] **Step 7: Settings keep the list, and read old exceptions once**

`Settings.swift`, replace `StoredSettings` with:

```swift
/// The user's choices, kept by the app.
public struct StoredSettings: Codable, Sendable, Equatable {
    public var mode: Mode = .direct
    public var bridge: BridgeKind? = .snowflake
    public var lines: [BridgeKind: [String]] = [:]
    /// The apps that go through Tor. nil: never set (filled with the
    /// installed browsers on first load).
    public var torApps: [AppID]?
    /// Exceptions saved by Tortuga 0.3 and older, read only to leave those
    /// apps out of the first list. Never written.
    public var legacyExceptions: [AppID] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, bridge, lines, torApps
        case legacyExceptions = "exceptions"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .direct
        bridge = try c.decodeIfPresent(BridgeKind.self, forKey: .bridge)
        lines = try c.decodeIfPresent([BridgeKind: [String]].self, forKey: .lines) ?? [:]
        torApps = try c.decodeIfPresent([AppID].self, forKey: .torApps)
        legacyExceptions = try c.decodeIfPresent([AppID].self, forKey: .legacyExceptions) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(bridge, forKey: .bridge)
        try c.encode(lines, forKey: .lines)
        try c.encodeIfPresent(torApps, forKey: .torApps)
    }
}
```

Note: the old synthesized coding wrote `bridge` as `null` for "no bridge"; `decodeIfPresent` reads `null` as nil, so that still means no bridge. A missing `bridge` key also means nil — but only JSON from before Tortuga stored a bridge could lack it, and that never shipped.

- [ ] **Step 8: ProxyEngine uses the list (seeding comes in Task 3)**

`ProxyEngine.swift`:

- `current`: replace `state.exceptions = settings.exceptions` with `state.torApps = settings.torApps ?? []`.
- Replace `addException` / `removeException` with:

```swift
    public func addTorApp(_ app: AppID) async throws {
        var list = settings.torApps ?? []
        guard !list.contains(app) else { return }
        list.append(app)
        settings.torApps = list
        try await settingsChanged()
    }

    public func removeTorApp(_ app: AppID) async throws {
        settings.torApps?.removeAll { $0 == app }
        try await settingsChanged()
    }
```

- `configuration()` keeps passing `exceptions:` for now, as `exceptions: []` (Task 4 replaces the field). Write it exactly so:

```swift
        ProxyConfiguration(bridge: settings.bridge, lines: settings.lines, exceptions: [],
                           helperPath: control.helperPaths.helper, ptDir: control.helperPaths.pt)
```

In `ProxyEngineTests.swift`, `settingsAreSavedAndReachTheExtension` becomes:

```swift
    @Test func settingsAreSavedAndReachTheExtension() async throws {
        let control = FakeControl()
        let store = MemoryStore()
        let engine = ProxyEngine(control: control, store: store)
        try await engine.setMode(.tor)
        try await engine.addTorApp(AppID("com.apple.Safari"))
        try await engine.selectBridge(nil)
        #expect(store.load().torApps == [AppID("com.apple.Safari")])
        #expect(store.load().bridge == nil)
        guard case .configure(let config) = control.link.commands.last else {
            Issue.record("no configure")
            return
        }
        #expect(config.bridge == nil)
        #expect(await engine.current.torApps == [AppID("com.apple.Safari")])
        try await engine.removeTorApp(AppID("com.apple.Safari"))
        #expect(store.load().torApps == [])
    }

    @Test func oldSettingsStillDecode() throws {
        let old = #"{"mode":"tor","bridge":null,"lines":{},"exceptions":[{"id":"com.apple.mail"}]}"#
        let settings = try JSONDecoder().decode(StoredSettings.self, from: Data(old.utf8))
        #expect(settings.mode == .tor)
        #expect(settings.bridge == nil)
        #expect(settings.torApps == nil)
        #expect(settings.legacyExceptions == [AppID("com.apple.mail")])
        let written = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!written.contains("exceptions"))
    }
```

- [ ] **Step 9: Keep TortugaUI building**

- Delete `ExceptionsView.swift`.
- `MainWindow.swift`: remove `case exceptions` from `SidebarSection` and its `title`, `symbol` and `detail` switch arms.
- `AppModel.swift`: in `Control`, rename `exceptions` to `apps`, and add these two methods after `perform`:

```swift
    /// Send an app through Tor; it becomes the selected row.
    public func addTorApp(_ app: AppID) async {
        expandedApp = app.id
        await perform(.apps) { try await $0.addTorApp(app) }
    }

    public func removeTorApp(_ app: AppID) async {
        if expandedApp == app.id { expandedApp = nil }
        await perform(.apps) { try await $0.removeTorApp(app) }
    }
```

- `RouteSummary.swift:15`: `state.apps.filter { !state.exceptions.contains($0.app) }` becomes `state.apps.filter { state.torApps.contains($0.app) }`.
- `StatusLine.swift:54`: `RouteList(apps: state.apps, exceptions: state.exceptions, now: .now)` becomes `RouteList(apps: state.apps, torApps: state.torApps, now: .now)`.
- `RouteView.swift`: the `RouteList(...)` call likewise; delete `ForEach(list.excepted) { ExceptedRow(app: $0) }` and the `ExceptedRow` struct; `model.errors[.exceptions]` becomes `model.errors[.apps]`; in `AppRow`, `exclude()` becomes

```swift
    private func exclude() {
        let app = route.app
        Task { await model.removeTorApp(app) }
    }
```

  and its two button titles "Exclude from Tor" become "Remove from Tortuga".
- `MenuPanel.swift:59-60`: `} else if state.exceptions.contains(app) {` / `Text("Connects directly: it's an exception.")` become `} else if !state.torApps.contains(app) {` / `Text("Connects directly: it isn't in Tortuga.")`.

In `macos/TortugaAppUITests/TortugaAppUITests.swift`, delete `testAnExceptionCanBeAddedAndRemoved` (Task 13 adds its replacement).

- [ ] **Step 10: Run all package tests and the app build**

Run each test command from the header (all three packages, then the xcodebuild line).
Expected: all pass; `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 11: Commit**

```bash
git add -A macos/Packages macos/TortugaAppUITests
git commit -m "feat(macos): a list of apps that go through Tor replaces exceptions"
```

---

### Task 3: The first list is the installed browsers

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/InstalledBrowsers.swift`
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift` (`init`)
- Modify: `macos/Tortuga/TortugaApp.swift` (`makeEngine`)
- Test: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/InstalledBrowsersTests.swift`, `ProxyEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

`InstalledBrowsersTests.swift`:

```swift
import Testing
import TortugaKit
@testable import TortugaProxyKit

private func app(_ id: String, _ path: String, _ name: String) -> InstalledBrowsers.Candidate {
    InstalledBrowsers.Candidate(id: id, path: path, name: name)
}

@Test func browsersAreKeptSortedByName() {
    let picked = InstalledBrowsers.pick([
        app("org.mozilla.firefox", "/Applications/Firefox.app", "Firefox"),
        app("com.apple.Safari", "/Applications/Safari.app", "Safari"),
        app("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome"),
    ], own: "org.tortuga.app")
    #expect(picked.map(\.id) == ["org.mozilla.firefox", "com.google.Chrome", "com.apple.Safari"])
    #expect(picked.first?.path == "/Applications/Firefox.app")
    #expect(picked.first?.name == "Firefox")
}

@Test func torBrowserTortugaAndBuildCopiesAreLeftOut() {
    let picked = InstalledBrowsers.pick([
        app("org.torproject.torbrowser", "/Applications/Tor Browser.app", "Tor Browser"),
        app("org.tortuga.app", "/Applications/Tortuga.app", "Tortuga"),
        app("com.brave.Browser", "/Volumes/Brave/Brave Browser.app", "Brave Browser"),
        app("com.example.dev", "/Users/a/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/Dev.app", "Dev"),
        app("com.example.local", "/Users/a/src/build/Build/Products/Release/Local.app", "Local"),
        app("com.apple.Safari", "/Applications/Safari.app", "Safari"),
    ], own: "org.tortuga.app")
    #expect(picked.map(\.id) == ["com.apple.Safari"])
}

@Test func theSameBrowserTwiceIsListedOnce() {
    let picked = InstalledBrowsers.pick([
        app("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome"),
        app("com.google.Chrome", "/Users/a/Applications/Google Chrome.app", "Google Chrome"),
    ], own: nil)
    #expect(picked.map(\.path) == ["/Applications/Google Chrome.app"])
}
```

Add to `ProxyEngineTests.swift` (inside the suite):

```swift
    @Test func theFirstListIsTheBrowsersMinusOldExceptions() async throws {
        let store = MemoryStore()
        var old = StoredSettings()
        old.legacyExceptions = [AppID("org.mozilla.firefox")]
        store.save(old)
        let engine = ProxyEngine(control: FakeControl(), store: store, installedBrowsers: {
            [AppID("com.apple.Safari"), AppID("org.mozilla.firefox")]
        })
        #expect(await engine.current.torApps == [AppID("com.apple.Safari")])
        #expect(store.load().torApps == [AppID("com.apple.Safari")])
    }

    @Test func aSavedListIsKept() async throws {
        let store = MemoryStore()
        var saved = StoredSettings()
        saved.torApps = [AppID("ru.keepcoder.Telegram")]
        store.save(saved)
        let engine = ProxyEngine(control: FakeControl(), store: store, installedBrowsers: { [AppID("com.apple.Safari")] })
        #expect(await engine.current.torApps == [AppID("ru.keepcoder.Telegram")])
    }
```

Check `MemoryStore` (in `ProxyEngineTests.swift`): `save` must keep the value and `load` return it. It already does; don't change it.

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos/Packages/TortugaProxyKit && swift test --filter "InstalledBrowsers|theFirstList|aSavedList"`
Expected: build errors (`InstalledBrowsers`, `installedBrowsers:` don't exist).

- [ ] **Step 3: Implement InstalledBrowsers**

```swift
import Foundation
import TortugaKit

/// Which apps make the first Tor list: the browsers on this Mac, found by
/// the app (apps that open https links), minus ones that shouldn't be there.
public enum InstalledBrowsers {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var path: String
        public var name: String

        public init(id: String, path: String, name: String) {
            self.id = id
            self.path = path
            self.name = name
        }
    }

    /// Tor Browser runs its own Tor; Tor over Tor only slows it down.
    static let excluded: Set<String> = ["org.torproject.torbrowser"]

    public static func pick(_ candidates: [Candidate], own: String?) -> [AppID] {
        var seen = Set<String>()
        return candidates
            .filter { !excluded.contains($0.id) && $0.id != own && !isBuildCopy($0.path) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { AppID($0.id, path: $0.path, name: $0.name) }
    }

    /// On a mounted disk image, or built by Xcode.
    static func isBuildCopy(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }
}
```

- [ ] **Step 4: Seed the list in ProxyEngine**

Replace `ProxyEngine.init` with:

```swift
    /// `installedBrowsers`: the first Tor list, asked for only when the
    /// settings have none yet.
    public init(control: any ProxyControl, store: any SettingsStore,
                installedBrowsers: @Sendable () -> [AppID] = { [] }) {
        self.control = control
        self.store = store
        var settings = store.load()
        if settings.torApps == nil {
            let skipped = Set(settings.legacyExceptions)
            settings.torApps = installedBrowsers().filter { !skipped.contains($0) }
            settings.legacyExceptions = []
            store.save(settings)
        }
        self.settings = settings
    }
```

- [ ] **Step 5: Run the tests**

Run: `cd macos/Packages/TortugaProxyKit && swift test`
Expected: all pass.

- [ ] **Step 6: The app finds the browsers**

In `macos/Tortuga/TortugaApp.swift`, `makeEngine()`: replace the `ProxyEngine(...)` line with

```swift
        let engine = ProxyEngine(control: SystemProxyControl(), store: DefaultsSettingsStore(),
                                 installedBrowsers: TortugaApp.installedBrowsers)
```

and add to `TortugaApp`:

```swift
    /// Apps that open https links, as the first Tor list.
    @Sendable static func installedBrowsers() -> [AppID] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        let candidates = urls.compactMap { url -> InstalledBrowsers.Candidate? in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return InstalledBrowsers.Candidate(id: id, path: url.path,
                                               name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        }
        return InstalledBrowsers.pick(candidates, own: Bundle.main.bundleIdentifier)
    }
```

- [ ] **Step 7: Build the app**

Run: `cd macos && xcodegen && xcodebuild -scheme Tortuga -destination 'platform=macOS' build-for-testing`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add macos/Packages/TortugaProxyKit macos/Tortuga/TortugaApp.swift
git commit -m "feat(macos): the first Tor list is the browsers installed on this Mac"
```

---

### Task 4: The extension routes only listed apps through Tor

**Files:**
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyMessages.swift` (`ProxyConfiguration`)
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/FlowRouter.swift`
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/RouteTable.swift`
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyCore.swift` (`publishRoutes`)
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift` (`configuration()`)
- Modify: `macos/TortugaProxy/TransparentProxy.swift`
- Test: `TortugaProxyKitTests/FlowRouterTests.swift`, `ProxyMessagesTests.swift`, `ProxyCoreTests.swift`, `ProxyEngineTests.swift`

- [ ] **Step 1: Rewrite the router tests**

In `FlowRouterTests.swift`, replace `ready` and the last two tests:

```swift
private let ready = RouterState(torReady: true, torApps: ["com.apple.Safari", "com.google.Chrome"],
                                own: ["org.tortuga.helper"])

@Test func aHelperUsesItsAppsCircuit() {
    #expect(FlowRouter.decide(flow(app: "com.google.Chrome.helper"), ready, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.google.Chrome"))
}

@Test func unlistedAppsGoDirect() {
    #expect(FlowRouter.decide(flow(app: "com.apple.mail"), ready, names: NameCache(), now: t0) == .unlisted)
}

@Test func ownAndLocalGoDirect() {
    #expect(FlowRouter.decide(flow(app: "org.tortuga.helper"), ready, names: NameCache(), now: t0) == .direct)
    #expect(FlowRouter.decide(flow(host: "printer.local", ip: "192.168.1.20"), ready, names: NameCache(), now: t0) == .direct)
}

@Test func onlyListedAppsWaitForTor() {
    let notReady = RouterState(torReady: false, torApps: ["com.apple.Safari"], own: [])
    #expect(FlowRouter.decide(flow(), notReady, names: NameCache(), now: t0) == .refuse)
    #expect(FlowRouter.decide(flow(app: "com.apple.mail"), notReady, names: NameCache(), now: t0) == .unlisted)
    #expect(FlowRouter.decide(flow(host: "router.lan", ip: "192.168.1.1"), notReady, names: NameCache(), now: t0) == .direct)
}

@Test func udpFromAListedAppIsRefused() {
    #expect(FlowRouter.decide(flow(udp: true), ready, names: NameCache(), now: t0) == .refuse)
}
```

The three `byName…`/`byIP…` tests stay: Safari is listed.

`ProxyMessagesTests.swift`: in `sampleConfig`, `exceptions: ["com.apple.mail"]` becomes `torApps: ["com.apple.Safari"]`. Line 34: `RouterState(torReady: true, exceptions: ["x"], …)` becomes `RouterState(torReady: true, torApps: ["x"], …)`; line 36: `.state.exceptions == ["x"]` becomes `.state.torApps == ["x"]`.

`ProxyCoreTests.swift:47`: `#expect(snapshot.state.exceptions == ["com.apple.mail"])` becomes `#expect(snapshot.state.torApps == ["com.apple.Safari"])`.

`ProxyEngineTests.swift`, in `settingsAreSavedAndReachTheExtension`, after `#expect(config.bridge == nil)` add:

```swift
        #expect(config.torApps == ["com.apple.Safari"])
```

(the remove at the end of that test happens after this check).

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos/Packages/TortugaProxyKit && swift test`
Expected: build errors (`torApps:`, `.unlisted`).

- [ ] **Step 3: Implement**

`ProxyMessages.swift`, in `ProxyConfiguration`: replace the `exceptions` property, its doc comment and the init parameter:

```swift
    /// Signing identifiers of the apps that go through Tor.
    public var torApps: [String]
```

```swift
    public init(bridge: BridgeKind?, lines: [BridgeKind: [String]], torApps: [String], helperPath: String, ptDir: String) {
        self.bridge = bridge
        self.lines = lines
        self.torApps = torApps
        self.helperPath = helperPath
        self.ptDir = ptDir
    }
```

`FlowRouter.swift`: in `RouterState` replace `exceptions` (property, comment, init parameter) with:

```swift
    /// Signing identifiers of the apps that go through Tor.
    public var torApps: Set<String>
```

```swift
    public init(torReady: Bool, torApps: Set<String>, own: Set<String>) {
        self.torReady = torReady
        self.torApps = torApps
        self.own = own
    }
```

In `FlowDecision`, after `case direct` add:

```swift
    /// Let macOS send it as usual: the app isn't in the Tor list.
    case unlisted
```

and replace `decide`:

```swift
    public static func decide(_ flow: FlowInfo, _ state: RouterState, names: NameCache, now: Date = .now) -> FlowDecision {
        if state.own.contains(flow.app) || LocalAddress.isLocal(flow.remoteIP) { return .direct }
        guard let listed = TorAppMatcher.match(flow.app, in: state.torApps) else { return .unlisted }
        if flow.isUDP || !state.torReady { return .refuse }
        let byName = flow.remoteHost.flatMap { $0.isEmpty ? nil : $0 }
        let host = byName ?? names.name(for: flow.remoteIP, now: now) ?? flow.remoteIP
        // The listed ID, not the helper's: an app and its helpers share a circuit.
        return .tor(host: host, port: flow.port, isolation: listed)
    }
```

Add `import TortugaKit` at the top of `FlowRouter.swift` if it isn't there.

`RouteTable.swift`: `RouterState(torReady: false, exceptions: [], own: ProxyCore.ownIDs)` becomes `RouterState(torReady: false, torApps: [], own: ProxyCore.ownIDs)`; in the doc comment "the exceptions" becomes "the Tor list".

`ProxyCore.swift`, `publishRoutes()`: `exceptions: Set(config?.exceptions ?? []),` becomes `torApps: Set(config?.torApps ?? []),`.

`ProxyEngine.swift`, `configuration()`:

```swift
        ProxyConfiguration(bridge: settings.bridge, lines: settings.lines, torApps: (settings.torApps ?? []).map(\.id),
                           helperPath: control.helperPaths.helper, ptDir: control.helperPaths.pt)
```

`macos/TortugaProxy/TransparentProxy.swift`: the type's doc comment becomes "to Tor by the app's own circuit for the apps in the Tor list, straight out for the rest and our own programs, or closed." In `handleNewFlow`, the `kind` line and the switch get the new case:

```swift
        let kind: String = switch decision { case .direct: "direct"; case .unlisted: "unlisted"; case .refuse: "refuse"; case .tor: "tor" }
```

```swift
        case .direct, .unlisted:
            return false
```

(Task 6 adds the recording to `.unlisted`.)

- [ ] **Step 4: Run the tests and build**

Run: `cd macos/Packages/TortugaProxyKit && swift test`, then the xcodebuild command.
Expected: all pass; `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit macos/TortugaProxy/TransparentProxy.swift
git commit -m "feat(macos): only apps in the Tor list go through Tor; helpers share their app's circuit"
```

---

### Task 5: DNS of unlisted apps goes to the system's resolver

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/DNSRoute.swift`
- Modify: `macos/TortugaProxy/DNSProxy.swift` (`handleNewFlow`, doc comment)
- Test: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/DNSRouteTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import TortugaProxyKit

private let list: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
private let own: Set<String> = ["tortuga-helper", "lyrebird"]

@Test func listedAppsAskTor() {
    #expect(DNSRoute.upstream(app: "com.apple.Safari", torApps: list, own: own, system: "192.168.1.1") == nil)
    #expect(DNSRoute.upstream(app: "com.google.Chrome.helper", torApps: list, own: own, system: "192.168.1.1") == nil)
}

@Test func unlistedAndOwnAskTheSystem() {
    #expect(DNSRoute.upstream(app: "com.apple.mail", torApps: list, own: own, system: "192.168.1.1") == "192.168.1.1")
    #expect(DNSRoute.upstream(app: "lyrebird", torApps: list, own: own, system: "192.168.1.1") == "192.168.1.1")
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd macos/Packages/TortugaProxyKit && swift test --filter DNSRoute`
Expected: build error, `cannot find 'DNSRoute'`.

- [ ] **Step 3: Implement**

```swift
import TortugaKit

/// Where a DNS query goes. A DNS flow can't be handed back to macOS
/// (returning false drops it, spike Q6), so queries that shouldn't go
/// through Tor are forwarded to the system's resolver.
public enum DNSRoute {
    /// The resolver to forward to, or nil to answer through Tor.
    public static func upstream(app: String, torApps: Set<String>, own: Set<String>, system: String) -> String? {
        if own.contains(app) || TorAppMatcher.match(app, in: torApps) == nil { return system }
        return nil
    }
}
```

- [ ] **Step 4: Use it in DNSProxy**

In `macos/TortugaProxy/DNSProxy.swift`, replace the doc comment's last two sentences with: "Queries from apps outside the Tor list, and from our own programs (Snowflake has to find its broker before Tor can start), go to the system's resolver." In `handleNewFlow`, replace the `own` and `upstream` lines with:

```swift
        let app = flow.metaData.sourceAppSigningIdentifier
        let routing = Shared.core.routes.snapshot().state
        let system = systemDNSSettings?.flatMap(\.servers).first ?? Self.resolvConfServer() ?? "1.1.1.1"
        let upstream = DNSRoute.upstream(app: app, torApps: routing.torApps, own: routing.own, system: system)
```

and in the log line after it replace `own: \(own)` with `listed: \(upstream == nil)`.

- [ ] **Step 5: Run the tests and build**

Run: `cd macos/Packages/TortugaProxyKit && swift test`, then the xcodebuild command.
Expected: all pass; `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/TortugaProxyKit macos/TortugaProxy/DNSProxy.swift
git commit -m "feat(macos): DNS of apps outside the Tor list goes to the system's resolver"
```

---

### Task 6: The extension remembers apps going direct

**Files:**
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyMessages.swift` (`ExtensionState`)
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyCore.swift`
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift` (`current`)
- Modify: `macos/TortugaProxy/TransparentProxy.swift`
- Test: `TortugaProxyKitTests/ProxyCoreTests.swift`, `ProxyEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `ProxyCoreTests` (the suite):

```swift
    @Test func appsGoingDirectAreRememberedForAnHour() async throws {
        let clock = TestClock()
        let core = ProxyCore(launcher: FakeLauncher(), retryDelay: .zero, now: { clock.now })
        await core.sawDirect(app: "com.apple.mail")
        clock.now += 10
        await core.sawDirect(app: "com.apple.Music")
        #expect(await core.current.seenDirect == ["com.apple.Music", "com.apple.mail"])
        clock.now += 3595
        await core.sawDirect(app: "com.apple.Music")
        #expect(await core.current.seenDirect == ["com.apple.Music"])
    }

    @Test func atMost200AppsAreRemembered() async throws {
        let clock = TestClock()
        let core = ProxyCore(launcher: FakeLauncher(), retryDelay: .zero, now: { clock.now })
        for i in 0..<205 {
            clock.now += 1
            await core.sawDirect(app: "app\(i)")
        }
        let seen = await core.current.seenDirect
        #expect(seen.count == 200)
        #expect(seen.first == "app204")
        #expect(!seen.contains("app4"))
    }
```

And at the bottom of `ProxyCoreTests.swift` (file scope):

```swift
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
```

(If a `TestClock` already exists in the test target, reuse it instead and skip this class.)

Add to `ProxyEngineTests`:

```swift
    @Test func seenDirectComesFromTheExtensionWithoutListedApps() async throws {
        let control = FakeControl()
        let store = MemoryStore()
        var saved = StoredSettings()
        saved.torApps = [AppID("com.apple.Safari")]
        store.save(saved)
        let engine = ProxyEngine(control: control, store: store)
        try await engine.setMode(.tor)
        control.link.push(ExtensionState(status: .on, trunk: Trunk(), apps: [],
                                         seenDirect: ["com.apple.mail", "com.apple.Safari"]))
        try await eventually { await engine.current.seenDirect == [AppID("com.apple.mail")] }
    }
```

(`eventually` is the helper the ProxyKit tests already use.)

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos/Packages/TortugaProxyKit && swift test --filter "Direct|200"`
Expected: build errors (`sawDirect`, `seenDirect`).

- [ ] **Step 3: Implement**

`ProxyMessages.swift`, `ExtensionState`:

```swift
public struct ExtensionState: Codable, Sendable, Equatable {
    public var status: Status
    public var trunk: Trunk
    public var apps: [AppRoute]
    /// Signing identifiers of apps that went direct in the last hour (not
    /// in the Tor list), most recent first.
    public var seenDirect: [String]

    public init(status: Status, trunk: Trunk, apps: [AppRoute], seenDirect: [String] = []) {
        self.status = status
        self.trunk = trunk
        self.apps = apps
        self.seenDirect = seenDirect
    }

    public static let idle = ExtensionState(status: .off, trunk: Trunk(), apps: [])
}
```

`ProxyCore.swift`: add to the stored properties

```swift
    /// Apps that went direct, by when they last did.
    private var direct: [String: Date] = [:]
    static let directWindow: TimeInterval = 3600
    static let directLimit = 200
```

add after `flowClosed`:

```swift
    /// An unlisted app's connection went directly. Published only when the
    /// set of apps changes, not on every connection.
    public func sawDirect(app: String) {
        let at = now()
        let before = Set(direct.keys)
        direct[app] = at
        direct = direct.filter { at.timeIntervalSince($0.value) <= Self.directWindow }
        if direct.count > Self.directLimit {
            let oldest = direct.sorted { $0.value > $1.value }.dropFirst(Self.directLimit).map(\.key)
            for key in oldest { direct[key] = nil }
        }
        if Set(direct.keys) != before || state.seenDirect.first != app {
            state.seenDirect = direct.sorted { $0.value > $1.value }.map(\.key)
            publish()
        }
    }
```

and in `stop()`, after `pending = [:]`, add `direct = [:]`. (`state = .idle` there already clears `seenDirect`.)

`ProxyEngine.swift`, `current`, inside `if link != nil { … }` add:

```swift
            let listed = Set(settings.torApps ?? [])
            state.seenDirect = remote.seenDirect.map { AppID($0) }.filter { !listed.contains($0) }
```

`macos/TortugaProxy/TransparentProxy.swift`, the switch in `handleNewFlow`:

```swift
        case .direct:
            return false
        case .unlisted:
            let app = info.app
            Task { await Shared.core.sawDirect(app: app) }
            return false
```

- [ ] **Step 4: Run the tests and build**

Run: `cd macos/Packages/TortugaProxyKit && swift test`, then the xcodebuild command.
Expected: all pass; `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit macos/TortugaProxy/TransparentProxy.swift
git commit -m "feat(macos): the extension remembers which apps went direct in the last hour"
```

---

### Task 7: Four times the dots

**Files:**
- Modify: `macos/tools/map-data/make-map-data.mjs:8,1`, `macos/tools/map-data/README.md`
- Regenerate: `macos/Packages/TortugaKit/Sources/TortugaKit/Resources/WorldMap.json`
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/MapProjection.swift`
- Test: `TortugaKitTests/WorldMapTests.swift`, `MapProjectionTests.swift`

- [ ] **Step 1: Write the failing tests**

`WorldMapTests.swift:7`: `#expect(map.dots.count > 1000)` becomes

```swift
    // A 1° grid: about 15,500 dots.
    #expect((14_000...17_000).contains(map.dots.count))
```

Add to `MapProjectionTests.swift`:

```swift
@Test func dotsGrowWithTheZoomWithinLimits() {
    let world = MapProjection(camera: MapCamera(centerLon: 0, centerLat: 13, lonSpan: 360, latSpan: 142),
                              in: CGSize(width: 600, height: 240), padding: 0)
    #expect(world.dotRadius == 0.85)
    let close = MapProjection(camera: MapCamera(centerLon: 10, centerLat: 50, lonSpan: 20, latSpan: 8),
                              in: CGSize(width: 600, height: 240), padding: 0)
    #expect(close.dotRadius == 3.2)
    let middle = MapProjection(camera: MapCamera(centerLon: 10, centerLat: 50, lonSpan: 100, latSpan: 10),
                               in: CGSize(width: 600, height: 240), padding: 0)
    #expect(abs(middle.dotRadius - 1.8) < 1e-9)
}
```

(600 points over 100° is 6 points per degree: 0.3 × 6 = 1.8.)

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos/Packages/TortugaKit && swift test --filter "WorldMap|dotsGrow"`
Expected: the count test fails (3890), the radius test doesn't build.

- [ ] **Step 3: Regenerate the data**

In `make-map-data.mjs` change `const STEP = 2;` to `const STEP = 1;` and the first comment line's "2° grid" to "1° grid". In `README.md` change any "2°" to "1°". Then:

```bash
cd macos/tools/map-data && npm ci && node make-map-data.mjs
```

Expected: `15496 dots, 236 countries → …/WorldMap.json`.

- [ ] **Step 4: Add dotRadius**

In `MapProjection.swift`, after `coordinate(at:)`:

```swift
    /// How big a land dot is drawn: about a third of a degree, but at least
    /// 0.85 points (the whole world) and at most 3.2 (close in).
    public var dotRadius: Double { min(max(0.3 * scale, 0.85), 3.2) }
```

- [ ] **Step 5: Run the tests**

Run: `cd macos/Packages/TortugaKit && swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add macos/tools/map-data macos/Packages/TortugaKit
git commit -m "feat(macos): four times the dots on the map (a 1° grid)"
```

---

### Task 8: MapProjection fits into the space beside the panel

**Files:**
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/MapProjection.swift`
- Test: `TortugaKitTests/MapProjectionTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func insetsMoveTheCentreIntoTheFreeSpace() {
    let camera = MapCamera(centerLon: 10, centerLat: 50, lonSpan: 40, latSpan: 20)
    let p = MapProjection(camera: camera, in: CGSize(width: 900, height: 600),
                          insets: MapInsets(top: 60, leading: 300, bottom: 20, trailing: 20))
    let centre = p.point(Coordinate(lon: 10, lat: 50))
    #expect(abs(centre.x - (300 + (900 - 320) / 2)) < 1e-9)
    #expect(abs(centre.y - (60 + (600 - 80) / 2)) < 1e-9)
}

@Test func uniformInsetsMatchPadding() {
    let camera = MapCamera(centerLon: 0, centerLat: 0, lonSpan: 60, latSpan: 30)
    let size = CGSize(width: 600, height: 240)
    #expect(MapProjection(camera: camera, in: size, insets: .uniform(24))
            == MapProjection(camera: camera, in: size, padding: 24))
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos/Packages/TortugaKit && swift test --filter "insets|uniformInsets"`
Expected: build error, `cannot find 'MapInsets'`.

- [ ] **Step 3: Implement**

In `MapProjection.swift`, above `MapProjection`:

```swift
/// Space kept clear around the map's routes, in points.
public struct MapInsets: Sendable, Equatable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static func uniform(_ value: CGFloat) -> MapInsets {
        MapInsets(top: value, leading: value, bottom: value, trailing: value)
    }
}
```

Replace `init(camera:in:padding:)` with these two:

```swift
    /// Shows at least the camera's spans around its centre, widened to the
    /// view's shape.
    public init(camera: MapCamera, in size: CGSize, padding: CGFloat) {
        // Padding takes at most half the view.
        let padding = max(0, min(padding, size.width / 2, size.height / 2))
        self.init(camera: camera, in: size, insets: .uniform(padding))
    }

    /// The same, inside the rectangle the insets leave (the routes avoid a
    /// panel over the map). A tiny floor keeps the scale finite.
    public init(camera: MapCamera, in size: CGSize, insets: MapInsets) {
        let width = max(Double(size.width - insets.leading - insets.trailing), 0.001)
        let height = max(Double(size.height - insets.top - insets.bottom), 0.001)
        // Widen to the view's shape around the centre.
        let latSpan = max(camera.latSpan, camera.lonSpan * height / width)
        let lonSpan = max(camera.lonSpan, latSpan * width / height)
        scale = min(width / lonSpan, height / latSpan)
        originLon = camera.centerLon - lonSpan / 2
        originLat = camera.centerLat + latSpan / 2
        offset = CGPoint(x: insets.leading + (width - lonSpan * scale) / 2,
                         y: insets.top + (height - latSpan * scale) / 2)
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd macos/Packages/TortugaKit && swift test`
Expected: all pass (the existing projection tests too).

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "feat(macos): MapProjection fits the routes inside insets"
```

---

### Task 9: The status pill and the problem banner

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/StatusPill.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/ProblemBanner.swift`
- Test: `macos/Packages/TortugaUI/Tests/TortugaUILogicTests/StatusPillTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import TortugaUI
import TortugaKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let relay = Relay(nickname: "r", country: "DE", address: "192.0.2.1")

private func state(_ status: Status, apps: Int = 0) -> EngineState {
    var s = EngineState()
    s.status = status
    s.trunk = Trunk(guardRelay: relay)
    s.torApps = (0..<apps).map { AppID("app\($0)") }
    s.apps = (0..<apps).map { AppRoute(app: AppID("app\($0)"), middle: relay, exit: relay, connections: 1, lastActive: now) }
    return s
}

@Test func offOffersTor() {
    let c = StatusPill.Content(state: state(.off), now: now, showsGuard: true)
    #expect(c.title == "Direct" && c.detail == "turn on Tor" && c.turnsOn && c.tone == .off)
}

@Test func startingShowsProgress() {
    let c = StatusPill.Content(state: state(.starting(step: "Building circuits", progress: 0.42)), now: now, showsGuard: true)
    #expect(c.title == "Connecting… 42%" && c.detail == "Building circuits" && c.progress == 0.42 && !c.turnsOn)
}

@Test func onCountsAppsAndNamesTheGuard() {
    let window = StatusPill.Content(state: state(.on, apps: 3), now: now, showsGuard: true)
    #expect(window.title == "Tor on" && window.detail == "3 apps · Guard 🇩🇪 Germany" && !window.turnsOn)
    let menu = StatusPill.Content(state: state(.on, apps: 1), now: now, showsGuard: false)
    #expect(menu.detail == "1 app")
    #expect(StatusPill.Content(state: state(.on), now: now, showsGuard: false).detail == "no traffic yet")
}

@Test func problemsSayWhatHappened() {
    let blocked = StatusPill.Content(state: state(.blocked(reason: "Tor stopped")), now: now, showsGuard: true)
    #expect(blocked.title == "Tor stopped" && blocked.detail == "Tor apps are blocked" && blocked.tone == .problem)
    let failed = StatusPill.Content(state: state(.failed(reason: "Snowflake can't reach its broker")), now: now, showsGuard: true)
    #expect(failed.title == "Snowflake can't reach its broker" && failed.detail.isEmpty && !failed.turnsOn)
}

@Test func theLabelReadsAsOneSentence() {
    let c = StatusPill.Content(state: state(.on, apps: 2), now: now, showsGuard: false)
    #expect(c.label == "Tor on, 2 apps")
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd macos/Packages/TortugaUI && swift test --filter StatusPill`
Expected: build error, `cannot find 'StatusPill'`.

- [ ] **Step 3: Implement StatusPill**

```swift
import SwiftUI
import TortugaKit

/// The status as a glass capsule, and the button that turns Tor on or off.
struct StatusPill: View {
    /// What the pill says, worked out from the state (tested on its own).
    struct Content: Equatable {
        enum Tone: Equatable { case off, starting, on, problem }

        var tone: Tone
        var title: String
        var detail: String
        /// Bootstrap progress, 0...1, while starting.
        var progress: Double?
        /// A click turns Tor on (else off).
        var turnsOn: Bool

        var label: String { detail.isEmpty ? title : "\(title), \(detail)" }

        init(state: EngineState, now: Date, showsGuard: Bool) {
            progress = nil
            turnsOn = false
            switch state.status {
            case .off:
                tone = .off
                title = "Direct"
                detail = "turn on Tor"
                turnsOn = true
            case .starting(let step, let p):
                tone = .starting
                title = "Connecting… \(Int(p * 100))%"
                detail = step
                progress = p
            case .on:
                tone = .on
                title = "Tor on"
                let n = RouteList(apps: state.apps, torApps: state.torApps, now: now).active.count
                var parts = [n == 0 ? "no traffic yet" : n == 1 ? "1 app" : "\(n) apps"]
                if showsGuard, let relay = state.trunk.guardRelay {
                    parts.append("Guard \(relay.flag) \(RouteSummary.country(relay.country))")
                }
                detail = parts.joined(separator: " · ")
            case .blocked(let reason):
                tone = .problem
                title = reason
                detail = "Tor apps are blocked"
            case .failed(let reason):
                tone = .problem
                title = reason
                detail = ""
            }
        }
    }

    @Environment(AppModel.self) private var model
    var showsGuard: Bool

    var body: some View {
        let content = Content(state: model.state, now: .now, showsGuard: showsGuard)
        Button { toggle(content) } label: {
            HStack(spacing: 8) {
                dot(content.tone)
                Text(content.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !content.detail.isEmpty {
                    Text("· \(content.detail)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "power").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(alignment: .leading) {
                if let progress = content.progress {
                    GeometryReader { geo in
                        Color.caution.opacity(0.25).frame(width: geo.size.width * progress)
                    }
                }
            }
            .clipShape(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background { Color.clear.glassEffect(.regular.interactive(), in: .capsule) }
        .accessibilityLabel(content.label)
        .accessibilityHint(content.turnsOn ? "Turns Tor on" : "Turns Tor off")
        .accessibilityIdentifier("status")
    }

    @ViewBuilder
    private func dot(_ tone: Content.Tone) -> some View {
        switch tone {
        case .off: Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        case .starting: Circle().fill(Color.caution).frame(width: 8, height: 8)
        case .on: Circle().fill(Color.route).frame(width: 8, height: 8)
            .background(Circle().fill(Color.route.opacity(0.25)).frame(width: 14, height: 14))
        case .problem: Circle().fill(.red).frame(width: 8, height: 8)
        }
    }

    private func toggle(_ content: Content) {
        let mode: Mode = content.turnsOn ? .tor : .direct
        Task { await model.perform(.mode) { try await $0.setMode(mode) } }
    }
}
```

- [ ] **Step 4: Implement ProblemBanner**

It takes over `StatusLine`'s buttons (read `StatusLine.swift` before Task 10 deletes it):

```swift
import AppKit
import SwiftUI
import TortugaKit

/// When Tor is blocked or failed, or a mode or restart command failed: what
/// happened and the next step.
struct ProblemBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.state.status
        let error = model.errors[.mode] ?? model.errors[.restart]
        let problem: String? = switch status {
        case .blocked(let reason): "\(reason) — Tor apps are blocked"
        case .failed(let reason): reason
        default: nil
        }
        if problem != nil || error != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("problem")
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if problem != nil {
                    HStack(spacing: 8) {
                        if status == .failed(reason: Status.allowExtensionReason) {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(Color.route)
                        }
                        Button("Restart") {
                            Task { await model.perform(.restart) { try await $0.restart() } }
                        }
                        .accessibilityIdentifier("restart")
                        if case .failed = status {
                            Button("Bridges…") {
                                model.section = .bridges
                                openWindow(id: "main")
                            }
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(14)
            .frame(maxWidth: 460, alignment: .leading)
            .glassCard(cornerRadius: 18)
        }
    }
}
```

(`model.section = .bridges` compiles because `SidebarSection.bridges` exists; Task 10 renames the type and keeps `.bridges`.)

- [ ] **Step 5: Run the tests**

Run: `cd macos/Packages/TortugaUI && swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): StatusPill, the status as the Tor button, and ProblemBanner"
```

---

### Task 10: The vertical route and the app panel

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/VerticalRoute.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/AppPanel.swift`
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/AppInfo.swift`, `AppModel.swift`
- Test: `macos/Packages/TortugaUI/Tests/TortugaUILogicTests/VerticalRouteTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import TortugaUI
import TortugaKit

private let guardRelay = Relay(nickname: "g", country: "DE", address: "192.0.2.1")
private let route = AppRoute(app: AppID("a"), middle: Relay(nickname: "Blåbär", country: "FR", address: "192.0.2.2"),
                             exit: Relay(nickname: "nyx", country: "SE", address: "185.220.101.4"),
                             connections: 3, lastActive: .now)

@Test func stopsRunFromTheMacToTheExit() {
    let stops = VerticalRoute.stops(Trunk(guardRelay: guardRelay), route)
    #expect(stops.map(\.kind) == [.mac, .guardRelay, .middle, .exit])
    #expect(stops.map(\.title) == ["Mac", "Guard", "Middle", "Exit"])
    #expect(stops.map(\.detail) == ["hidden", "Germany", "Blåbär", "185.220.101.4"])
    #expect(stops[2].flag == "🇫🇷")
}

@Test func aBridgeIsAStop() {
    let stops = VerticalRoute.stops(Trunk(bridge: .snowflake, guardRelay: guardRelay), route)
    #expect(stops.map(\.kind) == [.mac, .bridge, .guardRelay, .middle, .exit])
    #expect(stops[1].detail == "Snowflake")
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd macos/Packages/TortugaUI && swift test --filter VerticalRoute`
Expected: build error.

- [ ] **Step 3: Implement VerticalRoute**

```swift
import SwiftUI
import TortugaKit

/// One app's route, top to bottom: Mac, bridge, guard (the shared trunk, in
/// green and blue), then its middle and exit in the app's colour.
struct VerticalRoute: View {
    struct Stop: Identifiable, Equatable {
        enum Kind: Equatable { case mac, bridge, guardRelay, middle, exit }
        var kind: Kind
        var title: String
        var detail: String
        var flag: String?
        var id: String { title }
    }

    static func stops(_ trunk: Trunk, _ route: AppRoute) -> [Stop] {
        var stops = [Stop(kind: .mac, title: "Mac", detail: "hidden")]
        if let bridge = trunk.bridge {
            stops.append(Stop(kind: .bridge, title: "Bridge", detail: bridge.title))
        }
        if let relay = trunk.guardRelay {
            stops.append(Stop(kind: .guardRelay, title: "Guard", detail: RouteSummary.country(relay.country), flag: relay.flag))
        }
        stops.append(Stop(kind: .middle, title: "Middle", detail: route.middle.nickname, flag: route.middle.flag))
        stops.append(Stop(kind: .exit, title: "Exit", detail: route.exit.address, flag: route.exit.flag))
        return stops
    }

    let stops: [Stop]
    let color: Color
    var lit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { i, stop in
                HStack(spacing: 8) {
                    ZStack {
                        VStack(spacing: 0) {
                            Rectangle().fill(i == 0 ? .clear : line(stops[i].kind)).frame(width: 3)
                            Rectangle().fill(i == stops.count - 1 ? .clear : line(stops[i + 1].kind)).frame(width: 3)
                        }
                        Circle()
                            .fill(stop.kind == .exit && lit ? ring(stop.kind) : Color(nsColor: .windowBackgroundColor))
                            .strokeBorder(ring(stop.kind), lineWidth: 2.5)
                            .frame(width: 11, height: 11)
                    }
                    .frame(width: 12)
                    Text(stop.title).font(.caption.weight(.semibold))
                    if let flag = stop.flag { Text(flag).font(.caption) }
                    Text(stop.detail)
                        .font(stop.kind == .exit || stop.kind == .middle ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minHeight: 22)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stops.map { "\($0.title) \($0.detail)" }.joined(separator: ", "))
    }

    /// The segment that arrives at a stop of this kind.
    private func line(_ kind: Stop.Kind) -> Color {
        guard lit else { return .secondary.opacity(0.35) }
        return switch kind {
        case .bridge: .bridge
        case .mac, .guardRelay: .route
        case .middle, .exit: color
        }
    }

    private func ring(_ kind: Stop.Kind) -> Color {
        guard lit else { return .secondary }
        return switch kind {
        case .mac: .primary
        case .bridge: .bridge
        case .guardRelay: .route
        case .middle, .exit: color
        }
    }
}
```

- [ ] **Step 4: AppInfo and AppModel helpers**

`AppInfo.swift`, add:

```swift
    /// Whether the system finds an app bundle for it (daemons have none).
    static func isApp(_ app: AppID) -> Bool {
        url(app)?.pathExtension == "app"
    }
```

`AppModel.swift`, add after `removeTorApp`:

```swift
    /// An app the user picked in Finder.
    public func addApp(at url: URL) async {
        guard let app = AppInfo.id(forAppAt: url) else {
            let name = FileManager.default.displayName(atPath: url.path)
            errors[.apps] = "Tortuga can't route \(name): it has no bundle identifier."
            return
        }
        await addTorApp(app)
    }
```

Add `import Foundation` to `AppModel.swift` if `URL` doesn't resolve.

- [ ] **Step 5: Implement AppPanel**

```swift
import AppKit
import SwiftUI
import TortugaKit

/// The glass panel on the left of the map: the Tor list, a way to add apps,
/// and the apps seen going direct.
struct AppPanel: View {
    @Environment(AppModel.self) private var model
    static let width: CGFloat = 288

    var body: some View {
        let state = model.state
        let list = RouteList(apps: state.apps, torApps: state.torApps, now: .now)
        let lit = state.status == .on
        let direct = state.seenDirect.filter(AppInfo.isApp)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                title("THROUGH TOR")
                if state.torApps.isEmpty {
                    Text("No apps go through Tor. Add one with + Add app…")
                        .font(.caption).foregroundStyle(.secondary).padding(9)
                }
                ForEach(list.active) { TorAppRow(app: $0.app, route: $0, lit: lit, idle: false) }
                ForEach(list.idle) { TorAppRow(app: $0.app, route: $0, lit: lit, idle: true) }
                ForEach(list.waiting) { TorAppRow(app: $0, route: nil, lit: lit, idle: false) }
                Button(action: pickApp) {
                    Text("+ Add app…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .accessibilityIdentifier("add.app")
                if let error = model.errors[.apps] {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 9)
                }
                if !direct.isEmpty {
                    title("GOING DIRECT", note: "seen in the last hour").padding(.top, 10)
                    ForEach(direct) { DirectRow(app: $0) }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .glassCard(cornerRadius: 18)
    }

    private func title(_ text: String, note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.caption2.weight(.semibold)).tracking(0.5)
            if let note { Text("· \(note)").font(.caption2) }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Send through Tor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addApp(at: url) }
    }
}

/// A listed app. Click to open its route; the pointer over it shows −.
struct TorAppRow: View {
    @Environment(AppModel.self) private var model
    let app: AppID
    let route: AppRoute?
    let lit: Bool
    let idle: Bool
    @State private var hovering = false

    private var isOpen: Bool { model.expandedApp == app.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle().fill(lit && route != nil && !idle ? Color.app(app.id) : .secondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 24, height: 24)
                Text(AppInfo.name(app)).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                if idle {
                    Text("idle").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).overlay(Capsule().strokeBorder(.secondary.opacity(0.4)))
                } else if route == nil {
                    Text("no traffic yet").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let route, lit {
                    // Stays while hovered: the UI tests read it after a click.
                    Text("\(route.middle.flag) → \(route.exit.flag)")
                        .font(.callout)
                        .accessibilityIdentifier("row.exit.\(app.id)")
                        .accessibilityLabel(route.exit.address)
                }
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Tortuga")
                    .accessibilityLabel("Remove from Tortuga")
                    .accessibilityIdentifier("remove.\(app.id)")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(isOpen ? 0.10 : hovering ? 0.05 : 0)))
            .contentShape(.rect)
            .onTapGesture(perform: toggle)
            // Not a Button: a button merges its parts into one accessibility
            // element, and the exit should stay readable on its own.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggle)
            .accessibilityIdentifier("route.row.\(app.id)")

            if isOpen, let route, lit {
                VStack(alignment: .leading, spacing: 8) {
                    VerticalRoute(stops: VerticalRoute.stops(model.state.trunk, route), color: .app(app.id))
                    Text("\(route.connections) connections").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button("New circuit", systemImage: "arrow.clockwise", action: newCircuit)
                            .accessibilityIdentifier("circuit.\(app.id)")
                        TrashButton(action: remove)
                            .accessibilityIdentifier("trash.\(app.id)")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                .padding(.leading, 44)
                .padding(.bottom, 8)
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { model.hoveredApp = app.id } else if model.hoveredApp == app.id { model.hoveredApp = nil }
        }
        .contextMenu {
            Button("New circuit", action: newCircuit).disabled(route == nil)
            Button("Remove from Tortuga", action: remove)
        }
    }

    private func toggle() {
        withAnimation(.snappy) { model.expandedApp = isOpen ? nil : app.id }
    }

    private func newCircuit() {
        let app = app
        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
    }

    private func remove() {
        let app = app
        Task { await model.removeTorApp(app) }
    }
}

/// The trash icon that removes an app from the list; red under the pointer.
struct TrashButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").foregroundStyle(hovering ? Color.red : Color.primary)
        }
        .tint(hovering ? .red : nil)
        .help("Remove from Tortuga")
        .accessibilityLabel("Remove from Tortuga")
        .onHover { hovering = $0 }
    }
}

/// An unlisted app seen going direct, with + to send it through Tor.
struct DirectRow: View {
    @Environment(AppModel.self) private var model
    let app: AppID

    var body: some View {
        HStack(spacing: 9) {
            Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .frame(width: 8, height: 8)
            Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 24, height: 24)
            Text(AppInfo.name(app)).font(.body.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await model.addTorApp(app) }
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.route)
            }
            .buttonStyle(.plain)
            .help("Send through Tor")
            .accessibilityLabel("Send \(AppInfo.name(app)) through Tor")
            .accessibilityIdentifier("add.\(app.id)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .opacity(0.8)
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `cd macos/Packages/TortugaUI && swift test`
Expected: all pass (the panel isn't on screen yet; Task 11 puts it there).

- [ ] **Step 7: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): VerticalRoute and AppPanel, the Tor list over the map"
```

---

### Task 11: The map is the window

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/SectionSwitch.swift`
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/MainWindow.swift` (whole file), `AppModel.swift:14`, `RouteMap.swift`, `BridgesView.swift`, `Previews.swift`
- Delete: `RouteView.swift`, `ModeSwitch.swift`, `StatusLine.swift`
- Test: `macos/Packages/TortugaUI/Tests/TortugaUILogicTests/RouteMapCameraTests.swift`

- [ ] **Step 1: Write the failing tests (map motion)**

Add to `RouteMapCameraTests.swift`:

```swift
@Test func busierExitsPulseFaster() {
    #expect(RouteMap.pulsePeriod(connections: 0) == 3.2)
    #expect(abs(RouteMap.pulsePeriod(connections: 12) - 1.0) < 1e-9)
    #expect(abs(RouteMap.pulsePeriod(connections: 40) - 1.0) < 1e-9)
    #expect(RouteMap.pulsePeriod(connections: 6) < RouteMap.pulsePeriod(connections: 2))
}

@Test func trafficFlowsAtTwelvePointsASecond() {
    #expect(RouteMap.flowPhase(at: 0) == 0)
    #expect(abs(RouteMap.flowPhase(at: 0.5) - 6) < 1e-9)
    #expect(abs(RouteMap.flowPhase(at: 1.25) - 3) < 1e-9)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos/Packages/TortugaUI && swift test --filter "pulse|flows"`
Expected: build error.

- [ ] **Step 3: RouteMap: insets, dimming, flow, pulse, exit label, culled land**

In `RouteMap.swift`:

1. `RouteMap` gets two new stored properties after `focused`:

```swift
    /// Space kept clear of routes (the app panel and the toolbar cover it).
    var insets = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
    /// The Bridges card is over the map: dim land, no routes.
    var dimmed = false
```

   and two static helpers next to `camera(for:focused:)`:

```swift
    /// How long an active exit's pulse takes: 3.2 s with no connections,
    /// down to 1 s at twelve or more.
    static func pulsePeriod(connections: Int) -> Double {
        3.2 - Double(min(max(connections, 0), 12)) * (2.2 / 12)
    }

    /// The dash phase of the traffic flow: 12 points a second, repeating
    /// every dash (3 on, 9 off).
    static func flowPhase(at seconds: Double) -> Double {
        (seconds * 12).truncatingRemainder(dividingBy: 12)
    }
```

   In `body`, pass them on:

```swift
            RouteMapLayer(state: state, route: route, highlighted: highlighted, camera: camera,
                          size: geo.size, insets: insets, dimmed: dimmed, moving: !reduceMotion,
                          land: land, onSelect: onSelect)
```

2. `RouteMapLayer` gets `let insets: EdgeInsets`, `let dimmed: Bool`, `let moving: Bool` after `size`. Its `body` becomes:

```swift
    var body: some View {
        let projection = MapProjection(camera: camera, in: size,
                                       insets: MapInsets(top: insets.top, leading: insets.leading,
                                                         bottom: insets.bottom, trailing: insets.trailing))
        let landPath = land.path(for: projection, in: size)
        ZStack {
            TimelineView(.animation(minimumInterval: nil, paused: !moving || !lit || dimmed)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, _ in draw(route, projection, land: landPath, time: moving ? t : nil, in: &context) }
            }
            if !dimmed {
                ForEach(route.tails) { tail in
                    if let exit = tail.exit {
                        let p = projection.point(exit) + AppColor.offset(slot: tail.exitSlot)
                        Circle().fill(.clear).contentShape(.circle).frame(width: 16, height: 16)
                            .position(p)
                            .onTapGesture { onSelect(tail.id) }
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
```

3. `draw` gets a `time: Double?` parameter (nil: no motion). Replace it with:

```swift
    private func draw(_ route: MapRoute, _ projection: MapProjection, land: Path, time: Double?, in context: inout GraphicsContext) {
        context.fill(land, with: .color(.secondary.opacity(dimmed ? 0.14 : 0.28)))
        guard state.mode == .tor, !dimmed else { return }
        let flow = time.map { StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 9], dashPhase: -RouteMap.flowPhase(at: $0)) }

        if let mac = route.mac, let guardPlace = route.guardPlace {
            let color: Color = !lit ? .secondary.opacity(0.5) : route.bridge == nil ? .route : .bridge
            let style = route.bridge == .snowflake
                ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 5])
                : StrokeStyle(lineWidth: 3, lineCap: .round)
            let trunk = curve(projection.point(mac), projection.point(guardPlace))
            context.stroke(trunk, with: .color(color), style: style)
            if lit, let flow { context.stroke(trunk, with: .color(.white.opacity(0.7)), style: flow) }
        }

        for tail in route.tails {
            let faded = highlighted != nil && highlighted != tail.id
            let color = (lit ? Color.app(tail.id) : .secondary).opacity(faded ? 0.3 : 1)
            let start = tail.start.map(projection.point)
            let middle = tail.middle.map { projection.point($0) + AppColor.offset(slot: tail.middleSlot) }
            let exit = tail.exit.map { projection.point($0) + AppColor.offset(slot: tail.exitSlot) }
            let points = [start, middle, exit].compactMap { $0 }
            var path = Path()
            for (a, b) in zip(points, points.dropFirst()) { path.addPath(curve(a, b)) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: highlighted == tail.id ? 2.5 : 1.8, lineCap: .round))
            if lit, highlighted == tail.id, let flow { context.stroke(path, with: .color(.white.opacity(0.7)), style: flow) }
            if let middle { ring(middle, color, 3, in: &context) }
            if let exit {
                let appRoute = state.apps.first { $0.id == tail.id }
                if lit, !faded, let time, let appRoute, appRoute.connections > 0 {
                    let period = RouteMap.pulsePeriod(connections: appRoute.connections)
                    let f = time.truncatingRemainder(dividingBy: period) / period
                    let r = 4 + 9 * f
                    context.fill(Path(ellipseIn: CGRect(x: exit.x - r, y: exit.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(color.opacity(0.5 * (1 - f))))
                }
                context.fill(Path(ellipseIn: CGRect(x: exit.x - 4, y: exit.y - 4, width: 8, height: 8)), with: .color(color))
                if lit, highlighted == tail.id, let appRoute {
                    let label = "\(appRoute.exit.flag) \(RouteSummary.country(appRoute.exit.country))"
                    context.draw(Text(label).font(.caption.weight(.semibold)), at: CGPoint(x: exit.x + 10, y: exit.y), anchor: .leading)
                }
            }
        }

        if let mac = route.mac { ring(projection.point(mac), .primary, 4, in: &context) }
        if let guardPlace = route.guardPlace { ring(projection.point(guardPlace), lit ? .route : .secondary, 4, in: &context) }
    }
```

4. `LandCache.path(for:)` becomes `path(for:in:)`, keyed on the size too, sized by `dotRadius`, and skipping dots off screen:

```swift
@MainActor private final class LandCache {
    private var projection: MapProjection?
    private var size: CGSize = .zero
    private var path = Path()

    func path(for projection: MapProjection, in size: CGSize) -> Path {
        if projection != self.projection || size != self.size {
            let r = projection.dotRadius
            let visible = CGRect(origin: .zero, size: size).insetBy(dx: -r, dy: -r)
            var land = Path()
            for dot in WorldMap.shared.dots {
                let p = projection.point(dot)
                guard visible.contains(p) else { continue }
                land.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
            path = land
            self.projection = projection
            self.size = size
        }
        return path
    }
}
```

   Update its doc comment: "kept for the last projection and size; dots off screen are skipped."

- [ ] **Step 4: SectionSwitch**

```swift
import SwiftUI

public enum WindowSection: String, CaseIterable, Identifiable, Sendable {
    case route, bridges

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .route: "Route"
        case .bridges: "Bridges"
        }
    }
}

/// Route | Bridges, as one glass capsule in the toolbar.
struct SectionSwitch: View {
    @Binding var section: WindowSection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WindowSection.allCases) { item in
                let on = item == section
                Button { section = item } label: {
                    Text(item.title)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.primary.opacity(on ? 0.14 : 0)))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("section.\(item.rawValue)")
            }
        }
        .padding(3)
        .background { Color.clear.glassEffect(.regular, in: .capsule) }
    }
}
```

`AppModel.swift:14`: `public var section: SidebarSection = .route` becomes `public var section: WindowSection = .route`.

- [ ] **Step 5: MainWindow**

Replace `MainWindow.swift` with:

```swift
import SwiftUI
import TortugaKit

/// The window: the map fills it; the Tor list floats on the left, Route |
/// Bridges and the status pill sit in the toolbar, and the first-run card
/// shows until it's dismissed.
public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didShowWelcome") private var didShowWelcome = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        let onRoute = model.section == .route
        ZStack(alignment: .topLeading) {
            RouteMap(state: model.state,
                     highlighted: onRoute ? model.hoveredApp ?? model.expandedApp : nil,
                     focused: onRoute ? model.expandedApp : nil,
                     insets: EdgeInsets(top: 64, leading: onRoute ? AppPanel.width + 36 : 24, bottom: 24, trailing: 24),
                     dimmed: !onRoute) { id in
                withAnimation(.snappy) { model.expandedApp = id }
            }
            .ignoresSafeArea()

            if onRoute {
                AppPanel()
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                VStack {
                    ProblemBanner()
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.leading, AppPanel.width + 24)
                .frame(maxWidth: .infinity)
            } else {
                BridgesView()
                    .frame(width: 480)
                    .frame(maxHeight: 560)
                    .glassCard(cornerRadius: 20)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { SectionSwitch(section: $model.section) }
            ToolbarItem(placement: .primaryAction) { StatusPill(showsGuard: true) }
        }
        .navigationTitle("")
        .frame(minWidth: 700, minHeight: 640)
        .sheet(isPresented: Binding(get: { !didShowWelcome }, set: { if !$0 { didShowWelcome = true } })) {
            FirstRunView { didShowWelcome = true }
        }
    }
}
```

`RouteMap`'s initializer is memberwise: `insets` and `dimmed` must be declared in the order used here (after `focused`, before `region`), or the call won't compile.

`BridgesView.swift`: delete `.navigationTitle("Bridges")`, and add a title as the first line inside the `VStack`:

```swift
                Text("Bridges").font(.title3.weight(.bold))
```

- [ ] **Step 6: Delete the old views and fix the previews**

Delete `RouteView.swift`, `ModeSwitch.swift`, `StatusLine.swift`. `MenuPanel.swift` still uses `ModeSwitch` and `StatusLine`: in it, replace `ModeSwitch()` with `StatusPill(showsGuard: false)` and `StatusLine(showsAppCount: true)` with `ProblemBanner()` (Task 12 rewrites the menu). Delete `Status.text(bridge:)` from `Theme.swift` if nothing else calls it (`grep -rn "\.text(bridge" macos`).

`Previews.swift`: replace the two `RouteView()` previews with:

```swift
#Preview("Window, many apps") {
    PreviewHost(.manyApps) { MainWindow() }.frame(width: 900, height: 640)
}

#Preview("Window, Tor dies") {
    PreviewHost(.torDies) { MainWindow() }.frame(width: 900, height: 640)
}
```

- [ ] **Step 7: Build and test**

Run the three package test commands, then the xcodebuild command.
Expected: all pass; `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 8: Look at it**

Ask the user before launching the app. With their OK: `open` the built app with `-scenario normal -didShowWelcome YES -openWindowAtLaunch YES -showInDock YES` (the build product is under `~/Library/Developer/Xcode/DerivedData/Tortuga-*/Build/Products/Debug/Tortuga.app`), click the pill, and compare with `docs/mockups/map-window.html`: map full window, panel on the left, Route | Bridges centred, pill on the right, flow on the selected route, pulsing exits, Bridges card over a dim map. Fix anything that doesn't match before committing.

- [ ] **Step 9: Commit**

```bash
git add -A macos/Packages/TortugaUI
git commit -m "feat(macos): the map fills the window; Route | Bridges and the status pill in the toolbar"
```

---

### Task 12: The menu bar panel and the first-run text

**Files:**
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/MenuPanel.swift` (`MenuPanel.body`)
- Delete: `macos/Packages/TortugaUI/Sources/TortugaUI/MetroLine.swift`
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/FirstRunView.swift:14`
- Modify: `macos/project.yml` (`NSSystemExtensionUsageDescription`)

- [ ] **Step 1: Rewrite the panel**

Replace `MenuPanel` (keep `FrontApp` and `MenuBarLabel`) with:

```swift
/// The menu bar panel: the status pill, a problem if any, the front app's
/// route (or an offer to send it through Tor), actions.
public struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var front = FrontApp()

    public init() {}

    public var body: some View {
        let state = model.state
        let app = front.app
        let listed = app.map { state.torApps.contains($0) } ?? false
        let route = listed ? app.flatMap { app in state.apps.first { $0.app == app } } : nil
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(showsGuard: false)
            ProblemBanner()
            if let app {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 20, height: 20)
                        Text(AppInfo.name(app)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        if let route {
                            Text("\(route.connections) conn.").font(.caption).foregroundStyle(.secondary)
                        } else if !listed {
                            Text("direct").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let route, state.status == .on {
                        VerticalRoute(stops: VerticalRoute.stops(state.trunk, route), color: .app(route.id))
                    } else if listed {
                        Text("No traffic from \(AppInfo.name(app)) yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(AppInfo.name(app)) connects directly: it isn't in Tortuga.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Send \(AppInfo.name(app)) through Tor", systemImage: "plus") {
                            Task { await model.addTorApp(app) }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.route)
                        .accessibilityIdentifier("menu.add")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 16)
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button("New circuit", systemImage: "arrow.clockwise") {
                        guard let app = route?.app else { return }
                        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
                    }
                    .disabled(route == nil)
                    Button("Open Tortuga") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Remove MetroLine**

Delete `MetroLine.swift`. Run `grep -rn "MetroLine" macos/Packages macos/Tortuga`; expected: no output.

- [ ] **Step 3: Words**

`FirstRunView.swift:14`: the sentence becomes

```swift
                  "Tortuga sends your browsers through Tor, each on its own circuit, and any other app you add. Sites see a Tor exit, not your IP address.")
```

`macos/project.yml`: `NSSystemExtensionUsageDescription: Sends this Mac's traffic through Tor.` becomes `NSSystemExtensionUsageDescription: Sends the apps you choose through Tor.`

- [ ] **Step 4: Build and test**

Run the three package test commands, then the xcodebuild command.
Expected: all pass; `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A macos/Packages/TortugaUI macos/project.yml
git commit -m "feat(macos): the menu offers to send the front app through Tor"
```

---

### Task 13: UI tests

**Files:**
- Modify: `macos/TortugaAppUITests/TortugaAppUITests.swift`

- [ ] **Step 1: Update the tests to the new window**

- Every `press(app, "mode.tor")` becomes `press(app, "status")`.
- `waitForAllApps`: the last of the three demo apps to arrive is Firefox; routed rows have an exit, waiting ones don't:

```swift
    /// New apps join the top of the list and push the others down; wait for
    /// the last of the three so a click lands on the row it aims at.
    private func waitForAllApps(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "row.exit.org.mozilla.firefox").waitForExistence(timeout: 10))
    }
```

- `testRouteScreenHasTheMap`: replace `XCTAssertTrue(element(app, "route.guard").exists)` with

```swift
        waitFor(element(app, "status"), labelContaining: "Guard")
        press(app, "section.bridges")
        XCTAssertTrue(element(app, "bridge.obfs4").waitForExistence(timeout: 5))
        press(app, "section.route")
```

- `testTorDiesThenRestartBringsItBack`: `labelContaining: "traffic is blocked"` becomes `labelContaining: "Tor apps are blocked"`.
- `testABadObfs4LineIsMarkedAndAGoodOneSaved`: `press(app, "sidebar.bridges")` becomes `press(app, "section.bridges")`.
- Add:

```swift
    func testAnAppCanBeRemovedAndAddedBack() {
        let app = launch("normal")
        press(app, "status")
        waitForAllApps(app)
        let row = element(app, "route.row.com.apple.Safari")
        row.click()
        press(app, "trash.com.apple.Safari")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        let add = element(app, "add.com.apple.Safari")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        snap(app, "going-direct")
        add.click()
        XCTAssertTrue(element(app, "row.exit.com.apple.Safari").waitForExistence(timeout: 10))
    }
```

  `add.com.apple.Safari` shows only if `AppInfo.isApp` finds Safari, which it does on every Mac.

- [ ] **Step 2: Build**

Run: `cd macos && xcodegen && xcodebuild -scheme Tortuga -destination 'platform=macOS' build-for-testing`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the UI tests — ask the user first**

They take over the screen for a few minutes. With the user's OK:

```bash
cd macos && xcodebuild -scheme Tortuga -destination 'platform=macOS' test-without-building -only-testing:TortugaAppUITests
```

Expected: 5 tests pass. Keep the screenshots in the result bundle for the PR.

- [ ] **Step 4: Commit**

```bash
git add macos/TortugaAppUITests/TortugaAppUITests.swift
git commit -m "test(macos): UI tests for the Tor list and the map window"
```

---

### Task 14: Live check on this Mac, then the PR

- [ ] **Step 1: Everything passes**

Run all four test commands from the header. Expected: all pass.

- [ ] **Step 2: Install and check with the user**

Ask the user before reinstalling (`macos/scripts/install-dev.sh` replaces the installed app and the system extension; traffic goes direct for about a minute while macOS swaps the extension). Then, with the user watching:

1. Open the window. The list shows the installed browsers (Safari, Firefox, Chrome if installed), no Tor Browser.
2. Turn Tor on with the pill. In each browser, `https://check.torproject.org` says "Congratulations".
3. An unlisted app with a window (for example a browser removed from the list with the trash button, or another browser not in the list) opens `https://check.torproject.org` and sees "Sorry. You are not using Tor"; it appears under Going direct. Click `+`, reload: "Congratulations". Note: `curl` started from Terminal reports itself as `com.apple.curl`, but child processes count as their listed ancestor (found through the process tree), so with Terminal listed, `curl https://check.torproject.org/api/ip` from it shows `"IsTor":true`; with Terminal unlisted it goes direct. Likewise Firefox's WebRTC (`org.mozilla.plugincontainer`): with Firefox listed, browserleaks.com/webrtc must not show the Mac's public IP, and the log shows `flow udp from org.mozilla.plugincontainer: refuse via ancestor org.mozilla.firefox`.
3a. WebRTC: in each listed browser open a WebRTC leak test page (for example `https://browserleaks.com/webrtc`) and confirm no public IP of this Mac shows. Meanwhile watch the log for unlisted identifiers (`log stream --predicate 'subsystem == "org.tortuga.app"' | grep unlisted`): if a browser's child process (for example `org.mozilla.plugincontainer`) shows up as unlisted, extend `TorAppMatcher` with that case in this PR, with a test.
4. Chrome's traffic shows as one row. If a "Google Chrome Helper" row appears, read the logged identifier (`log show --last 5m --predicate 'subsystem == "org.tortuga.app"' | grep "flow tcp from"`) and extend `TorAppMatcher` with that case in this PR, with a test.
5. DNS: in the same log, `dns flow from com.apple.Safari … listed: true` and `dns flow from com.apple.Terminal … listed: false` (before Terminal was added).
6. Turn Tor off and on: while it connects, an unlisted app (curl from Terminal, with Terminal not listed) works; Safari waits.
7. Remove Telegram (or any added app) with the trash button: it moves to Going direct.
8. A flight between apps keeps 60 fps: Instruments → SwiftUI template, record while clicking between rows. If frames drop, apply the spec's fallback (cache the land as an image while the camera is still) in this PR.

- [ ] **Step 3: Open the PR (only when the user asks)**

Title: "Tor app list, and the map as the window". Body: what changed (the list replacing exceptions, DNS, Going direct, the window, the menu, 4× dots), the test counts, the live-check results, and the UI test screenshots. End with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
