# Tortuga for macOS, part 1 (interface on DemoEngine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS 26+ app with a menu bar item and a window
(Route, Bridges, Exceptions, Downloads, Settings, first run). It runs on a
simulated engine, `DemoEngine`, so it can be clicked through with no Tor and
no network.

**Architecture:** There are two Swift packages under `macos/Packages`.

- `TortugaKit` has no UI. It holds the models, the `TortugaEngine` protocol,
  the bridge line rules, the route-list grouping, and `DemoEngine`, an actor
  driven by simulated time so tests are exact.
- `TortugaUI` holds every view and `AppModel`, the `@Observable` bridge
  between the views and an engine.

The app target in `macos/Tortuga` only wires the scenes together. XcodeGen
generates the Xcode project from `macos/project.yml`.

**Tech Stack:** Swift 6 (language mode 6, tools 6.2), SwiftUI with Liquid
Glass (`glassEffect`, `GlassEffectContainer`, `.glass` and `.glassProminent`
button styles), Observation, swift-testing for the packages, XCTest/XCUITest
for the app, XcodeGen 2.46.

**Spec:** `docs/superpowers/specs/2026-11-09-macos-app-design.md`, section
"Part 1".

**Conventions for every task:**
- **Directory:** run commands from the repository root unless a step says
  otherwise.
- **Swift:** Swift 6 strict concurrency. Code must build without warnings.
- **Tests:** a package's tests run with
  `swift test --package-path macos/Packages/<Package>`.
- **Commits:** each message ends with the line
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

## File map

| File | Responsibility |
|---|---|
| `macos/Packages/TortugaKit/Package.swift` | package manifest |
| `…/TortugaKit/Sources/TortugaKit/Models.swift` | `Mode`, `Status`, `BridgeKind`, `Relay`, `AppID`, `Trunk`, `AppRoute`, `BridgeSettings`, `Download`, `DownloadSource`, `EngineState`, `Flag` |
| `…/TortugaKit/Sources/TortugaKit/BridgeLines.swift` | parse and check pasted bridge lines |
| `…/TortugaKit/Sources/TortugaKit/RouteList.swift` | sort app routes, fold idle ones, list exceptions |
| `…/TortugaKit/Sources/TortugaKit/TortugaEngine.swift` | the engine protocol and `EngineError` |
| `…/TortugaKit/Sources/TortugaKit/SeededRandom.swift` | deterministic random numbers |
| `…/TortugaKit/Sources/TortugaKit/DemoData.swift` | demo apps, relays, bridge lines, downloads |
| `…/TortugaKit/Sources/TortugaKit/DemoEngine.swift` | the simulated engine and `Scenario` |
| `…/TortugaKit/Tests/TortugaKitTests/*.swift` | tests for the above |
| `macos/Packages/TortugaUI/Package.swift` | package manifest |
| `…/TortugaUI/Sources/TortugaUI/AppModel.swift` | engine state and per-control errors for the views |
| `…/TortugaUI/Sources/TortugaUI/Theme.swift` | route/bridge/caution colours, status text and colour |
| `…/TortugaUI/Sources/TortugaUI/AppInfo.swift` | app name and icon from an `AppID` |
| `…/TortugaUI/Sources/TortugaUI/MetroLine.swift` | the metro-line view and its stop builders |
| `…/TortugaUI/Sources/TortugaUI/ModeSwitch.swift` | Direct / Tor capsule switch |
| `…/TortugaUI/Sources/TortugaUI/StatusLine.swift` | status dot, text, Restart and Bridges buttons |
| `…/TortugaUI/Sources/TortugaUI/RouteView.swift` | Route screen, app rows, excepted rows |
| `…/TortugaUI/Sources/TortugaUI/BridgesView.swift` | Bridges screen and cards |
| `…/TortugaUI/Sources/TortugaUI/ExceptionsView.swift` | Exceptions screen |
| `…/TortugaUI/Sources/TortugaUI/DownloadsView.swift` | Downloads screen and rows |
| `…/TortugaUI/Sources/TortugaUI/MainWindow.swift` | sidebar window and `SidebarSection` |
| `…/TortugaUI/Sources/TortugaUI/FirstRunView.swift` | first-run card |
| `…/TortugaUI/Sources/TortugaUI/MenuPanel.swift` | menu bar panel, `FrontApp`, `MenuBarLabel` |
| `…/TortugaUI/Sources/TortugaUI/SettingsView.swift` | Settings tabs (General, Downloads, About, Demo in debug) |
| `…/TortugaUI/Sources/TortugaUI/Previews.swift` | `PreviewHost` and previews |
| `…/TortugaUI/Tests/TortugaUIPackageTests/*.swift` | `AppModel`, status text and stop tests |
| `macos/project.yml`, `macos/Config/Base.xcconfig`, `macos/Local.xcconfig.example` | project and signing |
| `macos/Tortuga/TortugaApp.swift` | the app: scenes, engine, activation policy |
| `macos/TortugaAppUITests/TortugaAppUITests.swift` | XCUITest paths |
| `macos/README.md` | how to build, run and test |
| `.github/workflows/release.yml` | `macos-app` CI job |

---

### Task 1: Align the spec with names the code will use

The plan uses a few names that differ slightly from the approved spec. Fix
the spec so the two agree.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-09-macos-app-design.md`

- [ ] **Step 1: Apply these edits to the spec**
  - **Protocol:** in the `TortugaEngine` code block, replace
    `var states: AsyncStream<EngineState> { get }   // current state first, then every change`
    with
    `func states() async -> AsyncStream<EngineState>   // current state first, then every change`.
  - **`selectBridge`:** in the same block, replace
    `func selectBridge(_ kind: BridgeKind) async throws` with
    `func selectBridge(_ kind: BridgeKind?) async throws   // nil: no bridge`.
  - **`Trunk`:** in the models list, replace
    ``- `Trunk`: `bridge: BridgeKind?`, `guard: Relay?`.`` with
    ``- `Trunk`: `bridge: BridgeKind?`, `guardRelay: Relay?` (`guard` is a Swift keyword).``.
  - **`AppID`:** in the `AppID` bullet, after "optional bundle path", add
    "and an optional display name used when the app isn't installed".
  - **Layout:** in the layout block, replace
    `TortugaUITests/         XCUITest target` with
    `TortugaAppUITests/      XCUITest target`. Add the line
    `Config/Base.xcconfig    signing defaults; includes Local.xcconfig when present`.
  - **Scenario picker:** in the `DemoEngine` section, replace "Scenarios are
    picked in a Debug menu (debug builds)" with "Scenarios are picked in a Demo
    tab of Settings (debug builds; the app has no main menu while it runs from
    the menu bar)".
  - **Icon:** in the Icon bullet under "Menu bar item", replace the four
    states with:
    - `tortoise.fill` while Tor is on;
    - `tortoise.fill` with a pulse while connecting;
    - `exclamationmark.triangle.fill` while blocked or failed;
    - `tortoise` (outlined) in Direct.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-11-09-macos-app-design.md
git commit -m "docs(macos): name the engine's API as the code will" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: TortugaKit package and models

**Files:**
- Create: `macos/Packages/TortugaKit/Package.swift`
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/Models.swift`
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/ModelsTests.swift`
- Modify: `.gitignore`

- [ ] **Step 1: Ignore build products**

Append to `.gitignore`:

```
# macOS app (macos/)
macos/Tortuga.xcodeproj/
macos/Local.xcconfig
macos/build/
.build/
.swiftpm/
```

- [ ] **Step 2: Write the package manifest**

`macos/Packages/TortugaKit/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TortugaKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TortugaKit", targets: ["TortugaKit"])],
    targets: [
        .target(name: "TortugaKit"),
        .testTarget(name: "TortugaKitTests", dependencies: ["TortugaKit"]),
    ]
)
```

- [ ] **Step 3: Write the failing test**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/ModelsTests.swift`:

```swift
import Testing
@testable import TortugaKit

@Test func flagFromCountryCode() {
    #expect(Flag.emoji("de") == "🇩🇪")
    #expect(Flag.emoji("NL") == "🇳🇱")
    #expect(Flag.emoji("XYZ") == "🏳️")
    #expect(Flag.emoji("1A") == "🏳️")
}

@Test func appsAreTheSameByIdentifier() {
    #expect(AppID("com.apple.Safari", name: "Safari") == AppID("com.apple.Safari"))
    #expect(Set([AppID("a", path: "/x"), AppID("a")]).count == 1)
}

@Test func bridgeKinds() {
    #expect(BridgeKind.snowflake.needsLines == false)
    #expect(BridgeKind.obfs4.needsLines)
    #expect(BridgeKind.webtunnel.title == "WebTunnel")
    #expect(BridgeSettings().saved(.obfs4).isEmpty)
}

@Test func initialState() {
    let s = EngineState.initial
    #expect(s.mode == .direct)
    #expect(s.status == .off)
    #expect(s.apps.isEmpty)
}
```

- [ ] **Step 4: Run it to see it fail**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: build error, `cannot find 'Flag' in scope` (and the other types).

- [ ] **Step 5: Write the models**

`macos/Packages/TortugaKit/Sources/TortugaKit/Models.swift`:

```swift
import Foundation

/// Whether traffic goes through Tor.
public enum Mode: String, Sendable, Equatable, CaseIterable {
    case direct, tor
}

/// Where Tor is.
public enum Status: Sendable, Equatable {
    case off
    case starting(step: String, progress: Double)
    case on
    /// Tor stopped; traffic is held back until it runs again.
    case blocked(reason: String)
    /// Tor could not start.
    case failed(reason: String)
}

public enum BridgeKind: String, Sendable, Hashable, CaseIterable, Codable {
    case snowflake, obfs4, webtunnel

    public var title: String {
        switch self {
        case .snowflake: "Snowflake"
        case .obfs4: "obfs4"
        case .webtunnel: "WebTunnel"
        }
    }

    /// obfs4 and WebTunnel need bridge lines; Snowflake has built-in ones.
    public var needsLines: Bool { self != .snowflake }
}

public struct Relay: Sendable, Hashable {
    public var nickname: String
    /// ISO 3166 country code, like "DE".
    public var country: String
    public var address: String

    public init(nickname: String, country: String, address: String) {
        self.nickname = nickname
        self.country = country
        self.address = address
    }

    public var flag: String { Flag.emoji(country) }
}

/// An app, by its code-signing identifier. Two AppIDs are the same app when
/// their identifiers match; `path` and `name` only help to show it.
public struct AppID: Sendable, Hashable, Identifiable {
    public var id: String
    /// Where the app is, for apps the system can't find by identifier.
    public var path: String?
    /// A name to show when the app isn't installed.
    public var name: String?

    public init(_ id: String, path: String? = nil, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
    }

    public static func == (a: AppID, b: AppID) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The part of the route every app shares: the bridge and the guard.
public struct Trunk: Sendable, Equatable {
    public var bridge: BridgeKind?
    public var guardRelay: Relay?

    public init(bridge: BridgeKind? = nil, guardRelay: Relay? = nil) {
        self.bridge = bridge
        self.guardRelay = guardRelay
    }
}

/// One app's own part of the route.
public struct AppRoute: Sendable, Equatable, Identifiable {
    public var app: AppID
    public var middle: Relay
    public var exit: Relay
    public var connections: Int
    public var lastActive: Date

    public var id: String { app.id }

    public init(app: AppID, middle: Relay, exit: Relay, connections: Int, lastActive: Date) {
        self.app = app
        self.middle = middle
        self.exit = exit
        self.connections = connections
        self.lastActive = lastActive
    }
}

public struct BridgeSettings: Sendable, Equatable {
    /// nil: no bridge.
    public var selected: BridgeKind?
    /// Saved lines by kind, each starting with "Bridge ".
    public var lines: [BridgeKind: [String]]

    public init(selected: BridgeKind? = nil, lines: [BridgeKind: [String]] = [:]) {
        self.selected = selected
        self.lines = lines
    }

    public func saved(_ kind: BridgeKind) -> [String] { lines[kind] ?? [] }
}

public enum DownloadState: String, Sendable, Equatable {
    case downloading, sharing, paused, done, failed
}

public struct Download: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var size: Int64
    /// 0…1.
    public var done: Double
    /// Bytes per second.
    public var downRate: Int64
    public var upRate: Int64
    public var state: DownloadState
    public var error: String?

    public init(id: UUID = UUID(), name: String, size: Int64, done: Double = 0, downRate: Int64 = 0,
                upRate: Int64 = 0, state: DownloadState = .downloading, error: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.done = done
        self.downRate = downRate
        self.upRate = upRate
        self.state = state
        self.error = error
    }
}

public enum DownloadSource: Sendable, Equatable {
    case magnet(String)
    case file(URL)
}

public struct EngineState: Sendable, Equatable {
    public var mode: Mode = .direct
    public var status: Status = .off
    public var trunk = Trunk()
    public var apps: [AppRoute] = []
    public var bridges = BridgeSettings()
    public var exceptions: [AppID] = []
    public var downloads: [Download] = []

    public init() {}

    public static let initial = EngineState()
}

public enum Flag {
    /// The flag emoji for a two-letter country code, or a white flag.
    public static func emoji(_ code: String) -> String {
        let letters = Array(code.uppercased().unicodeScalars)
        guard letters.count == 2, letters.allSatisfy({ (65...90).contains($0.value) }) else { return "🏳️" }
        var flag = String.UnicodeScalarView()
        for letter in letters {
            if let scalar = Unicode.Scalar(0x1F1A5 + letter.value) { flag.append(scalar) }
        }
        return String(flag)
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: all 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add .gitignore macos/Packages/TortugaKit
git commit -m "feat(macos): TortugaKit package with the engine's models" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Bridge line rules

The same rules as `extension/src/lib/bridges.ts` (`isBridgeAddr`,
`parseLines`), so the app and the extension accept the same lines.

**Files:**
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/BridgeLines.swift`
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/BridgeLinesTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/BridgeLinesTests.swift`:

```swift
import Testing
@testable import TortugaKit

private let fp = String(repeating: "A1", count: 20)

@Test func addressRules() {
    #expect(BridgeLines.isAddress("192.0.2.1:443"))
    #expect(BridgeLines.isAddress("[2001:db8::1]:443"))
    #expect(!BridgeLines.isAddress("256.0.0.1:443"))
    #expect(!BridgeLines.isAddress("192.0.2.1:0"))
    #expect(!BridgeLines.isAddress("192.0.2.1:65536"))
    #expect(!BridgeLines.isAddress("[zz::1]:443"))
    #expect(!BridgeLines.isAddress("example.com:443"))
    #expect(!BridgeLines.isAddress("192.0.2.1"))
}

@Test func acceptsLinesWithOrWithoutBridge() {
    let text = "obfs4 192.0.2.1:443 \(fp) cert=x iat-mode=0\nBridge obfs4 [2001:db8::1]:443 \(fp)"
    let parsed = BridgeLines.parse(text, for: .obfs4)
    #expect(parsed.errors.isEmpty)
    #expect(parsed.lines == [
        "Bridge obfs4 192.0.2.1:443 \(fp) cert=x iat-mode=0",
        "Bridge obfs4 [2001:db8::1]:443 \(fp)",
    ])
}

@Test func skipsBlankLinesAndComments() {
    let parsed = BridgeLines.parse("\n# from the website\n  \nobfs4 192.0.2.1:443 \(fp)\n", for: .obfs4)
    #expect(parsed.lines.count == 1)
    #expect(parsed.errors.isEmpty)
}

@Test func reportsTheWrongTransport() {
    let parsed = BridgeLines.parse("webtunnel 192.0.2.1:443 \(fp)", for: .obfs4)
    #expect(parsed.errors == ["Line 1: starts with “webtunnel”, expected “obfs4”"])
}

@Test func reportsABadAddress() {
    let parsed = BridgeLines.parse("obfs4 example.com:443 \(fp)", for: .obfs4)
    #expect(parsed.errors == ["Line 1: no IP address:port after “obfs4” (like 192.0.2.1:443 or [2001:db8::1]:443)"])
}

@Test func reportsAMissingFingerprint() {
    let parsed = BridgeLines.parse("# c\nobfs4 192.0.2.1:443 nope", for: .obfs4)
    #expect(parsed.errors == ["Line 2: no 40-character fingerprint after the address"])
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: build error, `cannot find 'BridgeLines' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaKit/Sources/TortugaKit/BridgeLines.swift`:

```swift
import Foundation
import Network

/// Bridge lines pasted by the user, as bridges.torproject.org hands them out:
/// `obfs4 1.2.3.4:443 <40 hex> cert=… iat-mode=0`, with or without a leading
/// `Bridge`. The rules match the extension's (extension/src/lib/bridges.ts).
public enum BridgeLines {
    public struct Parsed: Sendable, Equatable {
        /// Good lines, each starting with "Bridge ".
        public var lines: [String]
        public var errors: [String]
    }

    /// `ip:port` as bridge lines have it: IPv4 or bracketed IPv6 (no host
    /// names: Arti takes neither) and a port from 1 to 65535.
    public static func isAddress(_ text: String) -> Bool {
        guard let match = text.wholeMatch(of: #/(?:(\d{1,3}(?:\.\d{1,3}){3})|\[([0-9A-Fa-f:.]+)\]):(\d{1,5})/#) else {
            return false
        }
        guard let port = Int(match.output.3), (1...65535).contains(port) else { return false }
        if let v4 = match.output.1 {
            return v4.split(separator: ".").allSatisfy { (Int($0) ?? 256) <= 255 }
        }
        if let v6 = match.output.2 {
            return IPv6Address(String(v6)) != nil
        }
        return false
    }

    public static func parse(_ text: String, for kind: BridgeKind) -> Parsed {
        var out = Parsed(lines: [], errors: [])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prefix = line.range(of: #"^Bridge\s+"#, options: [.regularExpression, .caseInsensitive]) {
                line.removeSubrange(prefix)
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let place = "Line \(index + 1)"
            let transport = parts[0]
            if transport != kind.rawValue {
                out.errors.append("\(place): starts with “\(transport)”, expected “\(kind.rawValue)”")
            } else if parts.count < 2 || !isAddress(parts[1]) {
                out.errors.append("\(place): no IP address:port after “\(kind.rawValue)” (like 192.0.2.1:443 or [2001:db8::1]:443)")
            } else if parts.count < 3 || parts[2].wholeMatch(of: #/[0-9A-Fa-f]{40}/#) == nil {
                out.errors.append("\(place): no 40-character fingerprint after the address")
            } else {
                out.lines.append("Bridge \(line)")
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: all tests pass (10).

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "feat(macos): bridge line rules, as the extension's" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Route list grouping

**Files:**
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/RouteList.swift`
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/RouteListTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/RouteListTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let relay = Relay(nickname: "r", country: "DE", address: "185.220.101.1")

private func route(_ id: String, secondsAgo: Double) -> AppRoute {
    AppRoute(app: AppID(id), middle: relay, exit: relay, connections: 1, lastActive: now.addingTimeInterval(-secondsAgo))
}

@Test func sortsByLastActivityAndFoldsIdleApps() {
    let list = RouteList(
        apps: [route("old", secondsAgo: 300), route("new", secondsAgo: 5), route("sleepy", secondsAgo: 601)],
        exceptions: [],
        now: now
    )
    #expect(list.active.map(\.id) == ["new", "old"])
    #expect(list.idle.map(\.id) == ["sleepy"])
}

@Test func leavesExceptedAppsOutOfTheRoutes() {
    let list = RouteList(apps: [route("mail", secondsAgo: 1), route("safari", secondsAgo: 2)],
                         exceptions: [AppID("mail")], now: now)
    #expect(list.active.map(\.id) == ["safari"])
    #expect(list.excepted == [AppID("mail")])
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: build error, `cannot find 'RouteList' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaKit/Sources/TortugaKit/RouteList.swift`:

```swift
import Foundation

/// The Route screen's rows: active apps (most recent first), apps idle for
/// more than ten minutes, and the excepted apps.
public struct RouteList: Sendable, Equatable {
    public static let idleAfter: TimeInterval = 600

    public var active: [AppRoute]
    public var idle: [AppRoute]
    public var excepted: [AppID]

    public init(apps: [AppRoute], exceptions: [AppID], now: Date) {
        let routed = apps
            .filter { !exceptions.contains($0.app) }
            .sorted { $0.lastActive > $1.lastActive }
        active = routed.filter { now.timeIntervalSince($0.lastActive) <= Self.idleAfter }
        idle = routed.filter { now.timeIntervalSince($0.lastActive) > Self.idleAfter }
        excepted = exceptions
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "feat(macos): group app routes into active, idle and excepted" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Engine protocol, seeded random numbers, demo data

**Files:**
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/TortugaEngine.swift`
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/SeededRandom.swift`
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/DemoData.swift`
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/DemoDataTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/DemoDataTests.swift`:

```swift
import Testing
@testable import TortugaKit

@Test func seededRandomRepeats() {
    var a = SeededRandom(seed: 42)
    var b = SeededRandom(seed: 42)
    #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
}

@Test func demoObfs4LinesAreValid() {
    let parsed = BridgeLines.parse(DemoData.obfs4Lines.joined(separator: "\n"), for: .obfs4)
    #expect(parsed.errors.isEmpty)
    #expect(parsed.lines.count == 7)
}

@Test func thirtyDistinctDemoApps() {
    #expect(Set(DemoData.manyApps).count == 30)
}

@Test func engineErrorReadsAsItsMessage() {
    #expect(EngineError("Tor isn't on").localizedDescription == "Tor isn't on")
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: build error, `cannot find 'SeededRandom' in scope`.

- [ ] **Step 3: Write the protocol**

`macos/Packages/TortugaKit/Sources/TortugaKit/TortugaEngine.swift`:

```swift
import Foundation

/// What the interface needs from whatever runs Tor: a stream of states and
/// commands. DemoEngine implements it now; the system extension's engine will
/// implement it in part 3.
public protocol TortugaEngine: AnyObject, Sendable {
    /// The current state first, then every change.
    func states() async -> AsyncStream<EngineState>
    func setMode(_ mode: Mode) async throws
    func restart() async throws
    /// nil: every app.
    func newCircuit(for app: AppID?) async throws
    /// nil: no bridge.
    func selectBridge(_ kind: BridgeKind?) async throws
    func saveBridgeLines(_ lines: [String], for kind: BridgeKind) async throws
    /// Lines from bridges.torproject.org (Moat).
    func fetchBridgeLines(_ kind: BridgeKind) async throws -> [String]
    func addException(_ app: AppID) async throws
    func removeException(_ app: AppID) async throws
    func addDownload(_ source: DownloadSource) async throws
    func pauseDownload(_ id: Download.ID) async throws
    func resumeDownload(_ id: Download.ID) async throws
    func removeDownload(_ id: Download.ID) async throws
}

/// An engine's refusal, in words to show the user as they are.
public struct EngineError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
```

- [ ] **Step 4: Write the random number generator**

`macos/Packages/TortugaKit/Sources/TortugaKit/SeededRandom.swift`:

```swift
/// SplitMix64: the same seed gives the same numbers, so demo sessions,
/// previews and tests repeat exactly.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

- [ ] **Step 5: Write the demo data**

`macos/Packages/TortugaKit/Sources/TortugaKit/DemoData.swift`:

```swift
import Foundation

/// What DemoEngine shows: real app identifiers and believable relays.
enum DemoData {
    static let countries = ["DE", "NL", "FR", "SE", "CH", "PL", "FI", "US", "CA", "RO", "IS", "NO", "AT", "CZ", "LU"]
    static let nicknames = ["Quintex", "ForPrivacyNET", "artikel10", "NTHrelay", "prsv", "relayon", "torpidsDE",
                            "CalyxInstitute", "emeraldonion", "nothingtohide", "Tortilla", "Spigot", "Hydra",
                            "Unnamed", "boldsuck"]

    /// Apps that connect one by one in the normal scenario.
    static let normalApps = [
        AppID("com.apple.Safari", name: "Safari"),
        AppID("ru.keepcoder.Telegram", name: "Telegram"),
        AppID("com.tinyspeck.slackmacgap", name: "Slack"),
        AppID("com.apple.Music", name: "Music"),
    ]

    /// Excepted from the start in the normal scenario.
    static let mail = AppID("com.apple.mail", name: "Mail")

    static let manyApps = [
        AppID("com.apple.Safari", name: "Safari"),
        AppID("ru.keepcoder.Telegram", name: "Telegram"),
        AppID("com.tinyspeck.slackmacgap", name: "Slack"),
        AppID("com.apple.Music", name: "Music"),
        AppID("com.google.Chrome", name: "Google Chrome"),
        AppID("org.mozilla.firefox", name: "Firefox"),
        AppID("us.zoom.xos", name: "zoom.us"),
        AppID("com.spotify.client", name: "Spotify"),
        AppID("com.hnc.Discord", name: "Discord"),
        AppID("net.whatsapp.WhatsApp", name: "WhatsApp"),
        AppID("org.whispersystems.signal-desktop", name: "Signal"),
        AppID("notion.id", name: "Notion"),
        AppID("com.figma.Desktop", name: "Figma"),
        AppID("com.microsoft.VSCode", name: "Visual Studio Code"),
        AppID("com.apple.dt.Xcode", name: "Xcode"),
        AppID("com.apple.Terminal", name: "Terminal"),
        AppID("com.apple.Maps", name: "Maps"),
        AppID("com.apple.news", name: "News"),
        AppID("com.apple.weather", name: "Weather"),
        AppID("com.apple.AppStore", name: "App Store"),
        AppID("com.apple.MobileSMS", name: "Messages"),
        AppID("com.apple.FaceTime", name: "FaceTime"),
        AppID("com.apple.Photos", name: "Photos"),
        AppID("com.apple.podcasts", name: "Podcasts"),
        AppID("com.apple.TV", name: "TV"),
        AppID("md.obsidian", name: "Obsidian"),
        AppID("com.1password.1password", name: "1Password"),
        AppID("com.getdropbox.dropbox", name: "Dropbox"),
        AppID("com.valvesoftware.steam", name: "Steam"),
        AppID("com.apple.mail", name: "Mail"),
    ]

    /// Seven well-formed obfs4 lines from documentation addresses.
    static let obfs4Lines: [String] = (1...7).map { i in
        let fingerprint = String(repeating: String(format: "%X", i), count: 40)
        return "Bridge obfs4 192.0.2.\(i):443 \(fingerprint) cert=ZGVtbyBjZXJ0aWZpY2F0ZQ iat-mode=0"
    }

    static func downloads() -> [Download] {
        [
            Download(name: "debian-13.2.0-arm64-netinst.iso", size: 754_974_720, done: 0.35,
                     downRate: 2_400_000, state: .downloading),
            Download(name: "archlinux-2026.11.01-x86_64.iso", size: 1_288_490_188, done: 1, state: .done),
        ]
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "feat(macos): engine protocol and demo data" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: DemoEngine: state stream, bootstrap, apps arriving

DemoEngine runs on simulated time. `advance(by:)` moves the time forward, and
tests call it directly. `startClock()` moves it in real time for the app. This
task adds the whole engine. Most of its commands are only tested in Task 7.

**Files:**
- Create: `macos/Packages/TortugaKit/Sources/TortugaKit/DemoEngine.swift`
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/DemoEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/DemoEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaKit

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func makeEngine(_ scenario: Scenario = .normal) -> DemoEngine {
    DemoEngine(scenario: scenario, seed: 1, start: t0)
}

@Suite struct DemoEngineBasics {
    @Test func startsOffWithSnowflakeSelected() async {
        let s = await makeEngine().current
        #expect(s.mode == .direct)
        #expect(s.status == .off)
        #expect(s.bridges.selected == .snowflake)
        #expect(s.exceptions == [DemoData.mail])
        #expect(s.downloads.count == 2)
    }

    @Test func streamStartsWithTheCurrentState() async throws {
        let engine = makeEngine()
        var states = await engine.states().makeAsyncIterator()
        #expect(await states.next()?.status == .off)
        try await engine.setMode(.tor)
        #expect(await states.next()?.mode == .tor)
    }

    @Test func torBootstrapsThenAppsArrive() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(2))
        #expect(await engine.current.status == .starting(step: "Loading the network", progress: 0.5))
        await engine.advance(by: .seconds(2))
        #expect(await engine.current.status == .on)
        #expect(await engine.current.trunk.bridge == .snowflake)
        #expect(await engine.current.trunk.guardRelay != nil)
        await engine.advance(by: .seconds(1))
        #expect(await engine.current.apps.map(\.app.id) == ["com.apple.Safari"])
        await engine.advance(by: .seconds(5))
        #expect(await engine.current.apps.count == 4)
    }

    @Test func directStopsEverything() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(10))
        try await engine.setMode(.direct)
        let s = await engine.current
        #expect(s.status == .off)
        #expect(s.apps.isEmpty)
        #expect(s.trunk == Trunk())
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: build error, `cannot find 'DemoEngine' in scope`.

- [ ] **Step 3: Implement DemoEngine**

`macos/Packages/TortugaKit/Sources/TortugaKit/DemoEngine.swift`:

```swift
import Foundation

public enum Scenario: String, Sendable, CaseIterable, Identifiable {
    case normal, slowBootstrap, bridgeFails, torDies, manyApps, empty
    public var id: String { rawValue }
}

/// A TortugaEngine that plays a believable session without a network, for
/// previews, tests and trying the interface before the real engine exists.
/// Time is simulated: `advance(by:)` moves it; `startClock()` moves it in
/// real time.
public actor DemoEngine: TortugaEngine {
    public static let tick: Duration = .milliseconds(100)
    static let steps = ["Starting Tor", "Reaching the bridge", "Loading the network", "Building circuits"]

    private enum Event { case arrive(AppID), newCircuit(AppID?), torDies }
    private struct Timer { let at: Duration; let event: Event }
    private struct Fetch {
        let at: Duration
        let kind: BridgeKind
        let reply: AsyncThrowingStream<[String], Error>.Continuation
    }

    public let scenario: Scenario
    private var state = EngineState()
    private var rng: SeededRandom
    private let start: Date
    private var elapsed: Duration = .zero
    private var bootStarted: Duration?
    private var died = false
    private var timers: [Timer] = []
    private var fetches: [Fetch] = []
    private var uploaded: [UUID: Double] = [:]
    private var observers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var clock: Task<Void, Never>?

    public init(scenario: Scenario = .normal, seed: UInt64 = 7, start: Date = .now) {
        self.scenario = scenario
        self.rng = SeededRandom(seed: seed)
        self.start = start
        state.bridges.selected = .snowflake
        if scenario != .empty && scenario != .manyApps {
            state.exceptions = [DemoData.mail]
            state.downloads = DemoData.downloads()
        }
    }

    /// A DemoEngine whose clock runs in real time.
    public static func running(_ scenario: Scenario) -> DemoEngine {
        let engine = DemoEngine(scenario: scenario)
        Task { await engine.startClock() }
        return engine
    }

    public var current: EngineState { state }
    /// Bridge-line requests waiting for their answer (for tests).
    public var pendingFetches: Int { fetches.count }

    public func startClock() {
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: DemoEngine.tick)
                guard let self else { return }
                await self.advance(by: DemoEngine.tick)
            }
        }
    }

    public func stopClock() {
        clock?.cancel()
        clock = nil
    }

    // MARK: TortugaEngine

    public func states() -> AsyncStream<EngineState> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.yield(state)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        return stream
    }

    public func setMode(_ mode: Mode) throws {
        state.mode = mode
        if mode == .tor {
            beginBootstrap()
        } else {
            stopTor()
            state.status = .off
        }
        publish()
    }

    public func restart() throws {
        guard state.mode == .tor else { throw EngineError("Switch to Tor first") }
        beginBootstrap()
        publish()
    }

    public func newCircuit(for app: AppID?) throws {
        guard state.status == .on else { throw EngineError("Tor isn't on") }
        schedule(.seconds(1), .newCircuit(app))
    }

    public func selectBridge(_ kind: BridgeKind?) throws {
        state.bridges.selected = kind
        if state.mode == .tor { beginBootstrap() }
        publish()
    }

    public func saveBridgeLines(_ lines: [String], for kind: BridgeKind) throws {
        guard kind.needsLines else { throw EngineError("Snowflake needs no lines") }
        let parsed = BridgeLines.parse(lines.joined(separator: "\n"), for: kind)
        if let first = parsed.errors.first { throw EngineError(first) }
        state.bridges.lines[kind] = parsed.lines
        publish()
    }

    public func fetchBridgeLines(_ kind: BridgeKind) async throws -> [String] {
        let (stream, reply) = AsyncThrowingStream<[String], Error>.makeStream()
        fetches.append(Fetch(at: elapsed + .milliseconds(500), kind: kind, reply: reply))
        for try await lines in stream { return lines }
        throw EngineError("No answer from bridges.torproject.org")
    }

    public func addException(_ app: AppID) throws {
        if !state.exceptions.contains(app) { state.exceptions.append(app) }
        state.apps.removeAll { $0.app == app }
        publish()
    }

    public func removeException(_ app: AppID) throws {
        state.exceptions.removeAll { $0 == app }
        publish()
    }

    public func addDownload(_ source: DownloadSource) throws {
        let name: String
        switch source {
        case .magnet(let link):
            guard link.hasPrefix("magnet:?") else { throw EngineError("Not a magnet link") }
            name = URLComponents(string: link)?.queryItems?.first { $0.name == "dn" }?.value ?? "Magnet link"
        case .file(let url):
            guard url.pathExtension.lowercased() == "torrent" else { throw EngineError("Not a .torrent file") }
            name = url.deletingPathExtension().lastPathComponent
        }
        state.downloads.append(Download(name: name, size: 1_073_741_824, downRate: 3_000_000))
        publish()
    }

    public func pauseDownload(_ id: Download.ID) throws {
        try update(id) { download in
            download.state = .paused
            download.downRate = 0
            download.upRate = 0
        }
    }

    public func resumeDownload(_ id: Download.ID) throws {
        try update(id) { download in
            if download.done >= 1 {
                download.state = .sharing
                download.upRate = 1_500_000
            } else {
                download.state = .downloading
                download.downRate = 2_400_000
            }
        }
    }

    public func removeDownload(_ id: Download.ID) throws {
        guard state.downloads.contains(where: { $0.id == id }) else { throw EngineError("No such download") }
        state.downloads.removeAll { $0.id == id }
        uploaded[id] = nil
        publish()
    }

    // MARK: Simulated time

    /// Move the simulated clock forward and apply whatever falls due.
    public func advance(by step: Duration) {
        elapsed += step
        var changed = stepBootstrap()
        let due = timers.filter { $0.at <= elapsed }
        timers.removeAll { $0.at <= elapsed }
        for timer in due {
            fire(timer.event)
            changed = true
        }
        let answered = fetches.filter { $0.at <= elapsed }
        fetches.removeAll { $0.at <= elapsed }
        for fetch in answered { answer(fetch) }
        if stepDownloads(step) { changed = true }
        if changed { publish() }
    }

    private var bootLength: Duration { scenario == .slowBootstrap ? .seconds(30) : .seconds(4) }
    private var now: Date { start.addingTimeInterval(elapsed.seconds) }

    private func beginBootstrap() {
        stopTor()
        if let kind = state.bridges.selected, kind.needsLines, state.bridges.saved(kind).isEmpty {
            state.status = .failed(reason: "Save \(kind.title) lines first, or pick another bridge")
            return
        }
        bootStarted = elapsed
        state.status = .starting(step: Self.steps[0], progress: 0)
    }

    private func stopTor() {
        bootStarted = nil
        timers.removeAll()
        state.trunk = Trunk()
        state.apps = []
    }

    private func stepBootstrap() -> Bool {
        guard let begun = bootStarted else { return false }
        let t = elapsed - begun
        if scenario == .bridgeFails, state.bridges.selected == .snowflake {
            if t >= .seconds(6) {
                bootStarted = nil
                state.status = .failed(reason: "Snowflake can't reach its broker")
            } else {
                state.status = .starting(step: Self.steps[1], progress: 0.25)
            }
            return true
        }
        if t >= bootLength {
            bootStarted = nil
            becomeOn()
            return true
        }
        let progress = t / bootLength
        let index = min(Int(progress * Double(Self.steps.count)), Self.steps.count - 1)
        state.status = .starting(step: Self.steps[index], progress: progress)
        return true
    }

    private func becomeOn() {
        state.status = .on
        state.trunk = Trunk(bridge: state.bridges.selected, guardRelay: relay())
        switch scenario {
        case .manyApps:
            var apps: [AppRoute] = []
            for (i, app) in DemoData.manyApps.enumerated() {
                let ago = i.isMultiple(of: 2) ? Double(i) : 1200 + Double(i)
                apps.append(route(app, lastActive: now.addingTimeInterval(-ago)))
            }
            state.apps = apps
        case .empty:
            break
        case .normal, .slowBootstrap, .bridgeFails, .torDies:
            for (i, app) in DemoData.normalApps.enumerated() {
                schedule(.seconds(1) + .milliseconds(1500 * i), .arrive(app))
            }
            if scenario == .torDies, !died { schedule(.seconds(5), .torDies) }
        }
    }

    private func fire(_ event: Event) {
        switch event {
        case .arrive(let app):
            guard state.status == .on, !state.exceptions.contains(app),
                  !state.apps.contains(where: { $0.app == app }) else { return }
            state.apps.append(route(app, lastActive: now))
        case .newCircuit(let app):
            for i in state.apps.indices where app == nil || state.apps[i].app == app {
                state.apps[i].middle = relay()
                state.apps[i].exit = relay()
            }
        case .torDies:
            guard state.status == .on else { return }
            died = true
            state.status = .blocked(reason: "Tor stopped")
        }
    }

    private func answer(_ fetch: Fetch) {
        switch fetch.kind {
        case .obfs4:
            fetch.reply.yield(DemoData.obfs4Lines)
            fetch.reply.finish()
        case .webtunnel:
            fetch.reply.finish(throwing: EngineError("bridges.torproject.org says none are needed here"))
        case .snowflake:
            fetch.reply.finish(throwing: EngineError("Snowflake needs no lines"))
        }
    }

    private func stepDownloads(_ step: Duration) -> Bool {
        let seconds = step.seconds
        var changed = false
        for i in state.downloads.indices {
            var download = state.downloads[i]
            switch download.state {
            case .downloading:
                download.done = min(1, download.done + Double(download.downRate) * seconds / Double(download.size))
                if download.done >= 1 {
                    download.state = .sharing
                    download.downRate = 0
                    download.upRate = 1_500_000
                }
            case .sharing:
                let sent = (uploaded[download.id] ?? 0) + Double(download.upRate) * seconds
                uploaded[download.id] = sent
                if sent >= Double(download.size) {
                    download.state = .done
                    download.upRate = 0
                }
            case .paused, .done, .failed:
                continue
            }
            state.downloads[i] = download
            changed = true
        }
        return changed
    }

    // MARK: Helpers

    private func update(_ id: Download.ID, _ change: (inout Download) -> Void) throws {
        guard let i = state.downloads.firstIndex(where: { $0.id == id }) else { throw EngineError("No such download") }
        change(&state.downloads[i])
        publish()
    }

    private func schedule(_ after: Duration, _ event: Event) {
        timers.append(Timer(at: elapsed + after, event: event))
    }

    private func relay() -> Relay {
        Relay(nickname: DemoData.nicknames.randomElement(using: &rng)!,
              country: DemoData.countries.randomElement(using: &rng)!,
              address: "185.220.\(Int.random(in: 100...109, using: &rng)).\(Int.random(in: 1...254, using: &rng))")
    }

    private func route(_ app: AppID, lastActive: Date) -> AppRoute {
        AppRoute(app: app, middle: relay(), exit: relay(),
                 connections: Int.random(in: 1...12, using: &rng), lastActive: lastActive)
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(state) }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: all tests pass, with no concurrency warnings in the build output.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "feat(macos): DemoEngine on simulated time" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: DemoEngine commands and scenarios

Tests only. If any test fails, fix `DemoEngine.swift` until the test reads as
the spec says; don't change the test.

**Files:**
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/DemoEngineCommandTests.swift`

- [ ] **Step 1: Write the tests**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/DemoEngineCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaKit

private let safari = AppID("com.apple.Safari")

@Suite struct DemoEngineCommands {
    @Test func newCircuitChangesTheExitAfterASecond() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(5))
        let before = try #require(await engine.current.apps.first { $0.app == safari }).exit
        try await engine.newCircuit(for: safari)
        await engine.advance(by: .milliseconds(900))
        #expect(await engine.current.apps.first { $0.app == safari }?.exit == before)
        await engine.advance(by: .milliseconds(100))
        #expect(await engine.current.apps.first { $0.app == safari }?.exit != before)
    }

    @Test func newCircuitNeedsTor() async {
        await #expect(throws: EngineError("Tor isn't on")) { try await makeEngine().newCircuit(for: nil) }
    }

    @Test func restartNeedsTor() async {
        await #expect(throws: EngineError("Switch to Tor first")) { try await makeEngine().restart() }
    }

    @Test func torDiesOnceAndRestartBringsItBack() async throws {
        let engine = makeEngine(.torDies)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.status == .on)
        await engine.advance(by: .seconds(5))
        #expect(await engine.current.status == .blocked(reason: "Tor stopped"))
        try await engine.restart()
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.status == .on)
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.status == .on)
    }

    @Test func slowBootstrapTakesThirtySeconds() async throws {
        let engine = makeEngine(.slowBootstrap)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(29))
        #expect(await engine.current.status != .on)
        await engine.advance(by: .seconds(1))
        #expect(await engine.current.status == .on)
    }

    @Test func snowflakeFailsInBridgeFailsButObfs4Works() async throws {
        let engine = makeEngine(.bridgeFails)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(6))
        #expect(await engine.current.status == .failed(reason: "Snowflake can't reach its broker"))
        try await engine.saveBridgeLines(DemoData.obfs4Lines, for: .obfs4)
        try await engine.selectBridge(.obfs4)
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.status == .on)
        #expect(await engine.current.trunk.bridge == .obfs4)
    }

    @Test func obfs4WithoutLinesFails() async throws {
        let engine = makeEngine()
        try await engine.selectBridge(.obfs4)
        try await engine.setMode(.tor)
        #expect(await engine.current.status == .failed(reason: "Save obfs4 lines first, or pick another bridge"))
    }

    @Test func noBridgeConnectsDirectlyToAGuard() async throws {
        let engine = makeEngine()
        try await engine.selectBridge(nil)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.trunk.bridge == nil)
        #expect(await engine.current.status == .on)
    }

    @Test func savingBadLinesThrowsTheFirstProblem() async {
        let engine = makeEngine()
        await #expect(throws: EngineError("Line 1: no 40-character fingerprint after the address")) {
            try await engine.saveBridgeLines(["obfs4 192.0.2.1:443 nope"], for: .obfs4)
        }
    }

    @Test func savedLinesStartWithBridge() async throws {
        let engine = makeEngine()
        try await engine.saveBridgeLines(["obfs4 192.0.2.1:443 \(String(repeating: "B", count: 40))"], for: .obfs4)
        #expect(await engine.current.bridges.saved(.obfs4).first?.hasPrefix("Bridge obfs4 ") == true)
    }

    @Test func fetchingObfs4LinesTakesHalfASecond() async throws {
        let engine = makeEngine()
        let fetch = Task { try await engine.fetchBridgeLines(.obfs4) }
        while await engine.pendingFetches == 0 { await Task.yield() }
        await engine.advance(by: .milliseconds(500))
        #expect(try await fetch.value.count == 7)
    }

    @Test func webTunnelLinesAreNotNeededHere() async throws {
        let engine = makeEngine()
        let fetch = Task { try await engine.fetchBridgeLines(.webtunnel) }
        while await engine.pendingFetches == 0 { await Task.yield() }
        await engine.advance(by: .milliseconds(500))
        await #expect(throws: EngineError("bridges.torproject.org says none are needed here")) { try await fetch.value }
    }

    @Test func exceptingAnAppDropsItsRouteAndKeepsItOut() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(5))
        try await engine.addException(safari)
        #expect(await engine.current.apps.isEmpty)
        #expect(await engine.current.exceptions.contains(safari))
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.apps.map(\.app.id) == ["ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap", "com.apple.Music"])
        try await engine.removeException(safari)
        #expect(await !engine.current.exceptions.contains(safari))
    }

    @Test func manyAppsShowsThirtyHalfOfThemIdle() async throws {
        let engine = makeEngine(.manyApps)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))
        let s = await engine.current
        #expect(s.apps.count == 30)
        let list = RouteList(apps: s.apps, exceptions: s.exceptions, now: t0.addingTimeInterval(4))
        #expect(list.active.count == 15)
        #expect(list.idle.count == 15)
    }

    @Test func emptyHasNoApps() async throws {
        let engine = makeEngine(.empty)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(20))
        #expect(await engine.current.status == .on)
        #expect(await engine.current.apps.isEmpty)
    }
}

@Suite struct DemoEngineDownloads {
    @Test func downloadsGrowAndPauseStopsThem() async throws {
        let engine = makeEngine()
        let first = await engine.current.downloads[0]
        await engine.advance(by: .seconds(10))
        let grown = await engine.current.downloads[0]
        #expect(grown.done > first.done)
        try await engine.pauseDownload(first.id)
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.downloads[0].done == grown.done)
        #expect(await engine.current.downloads[0].state == .paused)
        try await engine.resumeDownload(first.id)
        #expect(await engine.current.downloads[0].state == .downloading)
    }

    @Test func finishedDownloadsShareUntilRatioOne() async throws {
        let engine = makeEngine(.empty)
        try await engine.addDownload(.magnet("magnet:?xt=urn:btih:abc&dn=small.iso"))
        let id = await engine.current.downloads[0].id
        // 1 GiB at 3 MB/s takes about 358 s; sharing it back at 1.5 MB/s about 716 s.
        await engine.advance(by: .seconds(360))
        #expect(await engine.current.downloads[0].state == .sharing)
        await engine.advance(by: .seconds(720))
        #expect(await engine.current.downloads[0].state == .done)
        try await engine.removeDownload(id)
        #expect(await engine.current.downloads.isEmpty)
    }

    @Test func addingTakesTheMagnetsNameAndRefusesOtherFiles() async throws {
        let engine = makeEngine(.empty)
        try await engine.addDownload(.magnet("magnet:?xt=urn:btih:abc&dn=ubuntu.iso"))
        #expect(await engine.current.downloads.last?.name == "ubuntu.iso")
        try await engine.addDownload(.file(URL(fileURLWithPath: "/tmp/debian.torrent")))
        #expect(await engine.current.downloads.last?.name == "debian")
        await #expect(throws: EngineError("Not a .torrent file")) {
            try await engine.addDownload(.file(URL(fileURLWithPath: "/tmp/a.zip")))
        }
        await #expect(throws: EngineError("No such download")) { try await engine.removeDownload(UUID()) }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit`
Expected: all tests pass. If `finishedDownloadsShareUntilRatioOne` fails
because one tick of `advance(by: .seconds(360))` overshoots, look at it
carefully: `advance` applies the whole step at once, so 360 s is one
calculation. The download reaches 1.0 and becomes `.sharing`; sharing begins
on the next call. That is the intended behaviour.

- [ ] **Step 3: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "test(macos): DemoEngine commands and scenarios" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: TortugaUI package, AppModel, theme

**Files:**
- Create: `macos/Packages/TortugaUI/Package.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/AppModel.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/Theme.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/MainWindow.swift` (only `SidebarSection` for now)
- Create: `macos/Packages/TortugaUI/Tests/TortugaUIPackageTests/AppModelTests.swift`

- [ ] **Step 1: Write the manifest**

`macos/Packages/TortugaUI/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TortugaUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TortugaUI", targets: ["TortugaUI"])],
    dependencies: [.package(path: "../TortugaKit")],
    targets: [
        .target(name: "TortugaUI", dependencies: ["TortugaKit"]),
        .testTarget(name: "TortugaUIPackageTests", dependencies: ["TortugaUI", "TortugaKit"]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`macos/Packages/TortugaUI/Tests/TortugaUIPackageTests/AppModelTests.swift`:

```swift
import Testing
import TortugaKit
@testable import TortugaUI

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}

@MainActor @Suite struct AppModelTests {
    @Test func followsTheEngine() async throws {
        let model = AppModel(engine: DemoEngine(scenario: .normal))
        await model.perform(.mode) { try await $0.setMode(.tor) }
        try await waitUntil { model.state.mode == .tor }
        #expect(model.errors.isEmpty)
    }

    @Test func errorsLandOnTheirControlAndClearOnSuccess() async {
        let model = AppModel(engine: DemoEngine())
        await model.perform(.circuit) { try await $0.newCircuit(for: nil) }
        #expect(model.errors[.circuit] == "Tor isn't on")
        await model.perform(.circuit) { _ in }
        #expect(model.errors[.circuit] == nil)
    }

    @Test func replacingTheEngineStartsOver() async throws {
        let model = AppModel(engine: DemoEngine())
        await model.perform(.mode) { try await $0.setMode(.tor) }
        try await waitUntil { model.state.mode == .tor }
        model.replace(engine: DemoEngine(scenario: .empty))
        try await waitUntil { model.state.mode == .direct }
    }
}

@Test func statusTexts() {
    #expect(Status.on.text(bridge: .snowflake) == "Tor on via Snowflake")
    #expect(Status.on.text(bridge: nil) == "Tor on")
    #expect(Status.off.text(bridge: nil) == "Direct — not using Tor")
    #expect(Status.starting(step: "Building circuits", progress: 0.45).text(bridge: nil) == "Connecting… 45% · Building circuits")
    #expect(Status.blocked(reason: "Tor stopped").text(bridge: nil) == "Tor stopped — traffic is blocked")
    #expect(Status.failed(reason: "Snowflake can't reach its broker").text(bridge: .snowflake) == "Snowflake can't reach its broker")
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaUI`
Expected: build error, `cannot find 'AppModel' in scope`.

- [ ] **Step 4: Write AppModel**

`macos/Packages/TortugaUI/Sources/TortugaUI/AppModel.swift`:

```swift
import Observation
import TortugaKit

/// The views' side of an engine: its latest state, and errors filed under the
/// control whose command failed, so each shows next to that control.
@MainActor @Observable
public final class AppModel {
    public enum Control: Hashable, Sendable {
        case mode, restart, circuit, bridges, fetch, exceptions, downloads
    }

    public private(set) var state = EngineState.initial
    public private(set) var errors: [Control: String] = [:]
    public var section: SidebarSection = .route
    public private(set) var engine: any TortugaEngine
    @ObservationIgnored private var watcher: Task<Void, Never>?

    public init(engine: any TortugaEngine) {
        self.engine = engine
        watch()
    }

    /// Swap the engine (the Demo tab's scenario picker does this).
    public func replace(engine: any TortugaEngine) {
        watcher?.cancel()
        self.engine = engine
        state = .initial
        errors = [:]
        watch()
    }

    /// Run a command. A failure is filed under `control`; a success clears it.
    public func perform(_ control: Control,
                        _ command: @escaping @Sendable (any TortugaEngine) async throws -> Void) async {
        errors[control] = nil
        do {
            try await command(engine)
        } catch {
            errors[control] = error.localizedDescription
        }
    }

    /// Lines from bridges.torproject.org, or nil with the error under `.fetch`.
    public func fetchLines(_ kind: BridgeKind) async -> [String]? {
        errors[.fetch] = nil
        do {
            return try await engine.fetchBridgeLines(kind)
        } catch {
            errors[.fetch] = error.localizedDescription
            return nil
        }
    }

    private func watch() {
        let engine = engine
        watcher = Task { [weak self] in
            for await state in await engine.states() {
                guard !Task.isCancelled else { return }
                self?.state = state
            }
        }
    }
}
```

- [ ] **Step 5: Write the theme and status text**

`macos/Packages/TortugaUI/Sources/TortugaUI/Theme.swift`:

```swift
import AppKit
import SwiftUI
import TortugaKit

extension Color {
    /// The route green: the extension's --accent.
    static let route = Color(light: 0x16A34A, dark: 0x34D399)
    /// Bridges: the extension's --focus.
    static let bridge = Color(light: 0x2563EB, dark: 0x60A5FA)
    /// Connecting: the extension's --caution.
    static let caution = Color(light: 0xD97706, dark: 0xFBBF24)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

extension Status {
    func text(bridge: BridgeKind?) -> String {
        switch self {
        case .off: "Direct — not using Tor"
        case .starting(let step, let progress): "Connecting… \(Int(progress * 100))% · \(step)"
        case .on: bridge.map { "Tor on via \($0.title)" } ?? "Tor on"
        case .blocked(let reason): "\(reason) — traffic is blocked"
        case .failed(let reason): reason
        }
    }

    var color: Color {
        switch self {
        case .off: .secondary
        case .starting: .caution
        case .on: .route
        case .blocked, .failed: .red
        }
    }
}
```

- [ ] **Step 6: Write SidebarSection**

`macos/Packages/TortugaUI/Sources/TortugaUI/MainWindow.swift` (the window
itself comes in Task 13):

```swift
import SwiftUI
import TortugaKit

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case route, bridges, exceptions, downloads

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .route: "Route"
        case .bridges: "Bridges"
        case .exceptions: "Exceptions"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .bridges: "road.lanes"
        case .exceptions: "arrow.uturn.right"
        case .downloads: "arrow.down.circle"
        }
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaUI`
Expected: all 4 tests pass.

- [ ] **Step 8: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): TortugaUI package with AppModel and theme" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Metro line, app info, mode switch, status line

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/MetroLine.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/AppInfo.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/ModeSwitch.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/StatusLine.swift`
- Create: `macos/Packages/TortugaUI/Tests/TortugaUIPackageTests/MetroStopsTests.swift`

- [ ] **Step 1: Write the failing tests for the stop builders**

`macos/Packages/TortugaUI/Tests/TortugaUIPackageTests/MetroStopsTests.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaUI

private let de = Relay(nickname: "g", country: "DE", address: "1.1.1.1")
private let nl = Relay(nickname: "m", country: "NL", address: "2.2.2.2")
private let se = Relay(nickname: "e", country: "SE", address: "3.3.3.3")

@Test func trunkWithBridgeAndGuard() {
    let stops = MetroLine.Stop.trunk(Trunk(bridge: .snowflake, guardRelay: de))
    #expect(stops.map(\.id) == ["you", "bridge", "guard"])
    #expect(stops[1].kind == .bridge(.snowflake))
    #expect(stops[2].flag == "🇩🇪")
}

@Test func trunkWithoutTor() {
    #expect(MetroLine.Stop.trunk(Trunk()).map(\.id) == ["you"])
}

@Test func fullRouteEndsAtTheExit() {
    let route = AppRoute(app: AppID("a"), middle: nl, exit: se, connections: 1, lastActive: .now)
    let stops = MetroLine.Stop.full(Trunk(guardRelay: de), route)
    #expect(stops.map(\.id) == ["you", "guard", "middle", "exit"])
    #expect(stops.last?.kind == .exit)
    #expect(MetroLine.Stop.tail(route).map(\.id) == ["middle", "exit"])
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaUI`
Expected: build error, `cannot find 'MetroLine' in scope`.

- [ ] **Step 3: Write the metro line**

`macos/Packages/TortugaUI/Sources/TortugaUI/MetroLine.swift`:

```swift
import AppKit
import SwiftUI
import TortugaKit

/// A route drawn as a metro line: stations evenly spaced, a flag above each
/// relay, and a title and detail under each station (not when compact).
struct MetroLine: View {
    struct Stop: Identifiable, Equatable {
        enum Kind: Equatable {
            case you, bridge(BridgeKind), relay, exit

            var isBridge: Bool {
                if case .bridge = self { true } else { false }
            }
        }

        var id: String
        var kind: Kind
        var title: String
        var detail: String
        var flag: String?
    }

    var stops: [Stop]
    var lit: Bool
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            if !compact, stops.contains(where: { $0.flag != nil }) {
                columns { Text($0.flag ?? " ").font(.callout) }
            }
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: compact ? 10 : 16)
            if !compact {
                columns { stop in
                    VStack(spacing: 1) {
                        Text(stop.title).font(.caption.weight(.semibold))
                        Text(stop.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stops.map { "\($0.title) \($0.detail)" }.joined(separator: ", "))
    }

    private func columns<Content: View>(@ViewBuilder _ content: @escaping (Stop) -> Content) -> some View {
        HStack(spacing: 0) {
            ForEach(stops) { stop in
                content(stop).lineLimit(1).frame(maxWidth: .infinity)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !stops.isEmpty else { return }
        let column = size.width / CGFloat(stops.count)
        let y = size.height / 2
        let radius = compact ? 4.0 : 6.0
        func x(_ i: Int) -> CGFloat { column * (CGFloat(i) + 0.5) }

        for i in stops.indices.dropFirst() {
            var path = Path()
            path.move(to: CGPoint(x: x(i - 1), y: y))
            path.addLine(to: CGPoint(x: x(i), y: y))
            let color: Color = !lit ? .secondary.opacity(0.35) : stops[i].kind.isBridge ? .bridge : .route
            let style = stops[i].kind == .bridge(.snowflake)
                ? StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round, dash: [1, compact ? 4 : 6])
                : StrokeStyle(lineWidth: compact ? 3 : 5, lineCap: .round)
            context.stroke(path, with: .color(color), style: style)
        }

        for (i, stop) in stops.enumerated() {
            let circle = Path(ellipseIn: CGRect(x: x(i) - radius, y: y - radius, width: radius * 2, height: radius * 2))
            let ring: Color = !lit ? .secondary : stop.kind == .you ? .primary : stop.kind.isBridge ? .bridge : .route
            let fill: Color = lit && stop.kind == .exit ? .route : Color(nsColor: .windowBackgroundColor)
            context.fill(circle, with: .color(fill))
            context.stroke(circle, with: .color(ring), lineWidth: compact ? 2 : 3)
        }
    }
}

extension MetroLine.Stop {
    /// The shared part: this Mac, the bridge if any, the guard once known.
    static func trunk(_ t: Trunk) -> [Self] {
        var stops = [Self(id: "you", kind: .you, title: "Mac", detail: "hidden")]
        if let bridge = t.bridge {
            stops.append(Self(id: "bridge", kind: .bridge(bridge), title: "Bridge", detail: bridge.title))
        }
        if let relay = t.guardRelay {
            stops.append(Self(id: "guard", kind: .relay, title: "Guard", detail: relay.country, flag: relay.flag))
        }
        return stops
    }

    /// One app's own part: middle and exit.
    static func tail(_ route: AppRoute) -> [Self] {
        [
            Self(id: "middle", kind: .relay, title: "Middle", detail: route.middle.country, flag: route.middle.flag),
            Self(id: "exit", kind: .exit, title: "Exit", detail: route.exit.country, flag: route.exit.flag),
        ]
    }

    static func full(_ t: Trunk, _ route: AppRoute) -> [Self] {
        trunk(t) + tail(route)
    }
}
```

- [ ] **Step 4: Write AppInfo**

`macos/Packages/TortugaUI/Sources/TortugaUI/AppInfo.swift`:

```swift
import AppKit
import TortugaKit

/// Names and icons for apps, from the system (the engine sends only IDs).
@MainActor
enum AppInfo {
    static func url(_ app: AppID) -> URL? {
        if let path = app.path { return URL(fileURLWithPath: path) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
    }

    static func name(_ app: AppID) -> String {
        if let url = url(app) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return app.name ?? app.id
    }

    static func icon(_ app: AppID) -> NSImage {
        if let url = url(app) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    /// The AppID of an app the user picked in Finder.
    static func id(forAppAt url: URL) -> AppID? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return AppID(id, path: url.path, name: FileManager.default.displayName(atPath: url.path))
    }
}
```

- [ ] **Step 5: Write the mode switch**

`macos/Packages/TortugaUI/Sources/TortugaUI/ModeSwitch.swift`:

```swift
import SwiftUI
import TortugaKit

/// Direct / Tor as two glass capsules; the current one is prominent.
struct ModeSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                option(.direct, "Direct")
                option(.tor, "Tor")
            }
        }
    }

    @ViewBuilder
    private func option(_ mode: Mode, _ title: String) -> some View {
        let button = Button(title) {
            Task { await model.perform(.mode) { try await $0.setMode(mode) } }
        }
        .accessibilityIdentifier("mode.\(mode.rawValue)")
        if model.state.mode == mode {
            button.buttonStyle(.glassProminent).tint(mode == .tor ? Color.route : .secondary)
                .accessibilityAddTraits(.isSelected)
        } else {
            button.buttonStyle(.glass)
        }
    }
}
```

- [ ] **Step 6: Write the status line**

`macos/Packages/TortugaUI/Sources/TortugaUI/StatusLine.swift`:

```swift
import SwiftUI
import TortugaKit

/// The status with its dot, and the next step when something is wrong.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(state.status.color).frame(width: 8, height: 8)
                Text(state.status.text(bridge: state.trunk.bridge ?? state.bridges.selected))
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("status")
                Spacer(minLength: 0)
                switch state.status {
                case .blocked, .failed:
                    Button("Restart") {
                        Task { await model.perform(.restart) { try await $0.restart() } }
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("restart")
                    if case .failed = state.status {
                        Button("Bridges…") {
                            model.section = .bridges
                            openWindow(id: "main")
                        }
                        .buttonStyle(.glass)
                    }
                default:
                    EmptyView()
                }
            }
            if let error = model.errors[.mode] ?? model.errors[.restart] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
```

- [ ] **Step 7: Run the tests and build**

Run: `swift test --package-path macos/Packages/TortugaUI`
Expected: all tests pass (7).

- [ ] **Step 8: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): metro line, mode switch and status line" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Route screen

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/RouteView.swift`

- [ ] **Step 1: Write the Route screen**

`macos/Packages/TortugaUI/Sources/TortugaUI/RouteView.swift`:

```swift
import SwiftUI
import TortugaKit

/// The shared trunk, then a row per app: active first, idle folded, excepted last.
struct RouteView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: String?

    var body: some View {
        let state = model.state
        let list = RouteList(apps: state.apps, exceptions: state.exceptions, now: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusLine()
                MetroLine(stops: MetroLine.Stop.trunk(state.trunk), lit: state.status == .on)
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                if state.status == .on, list.active.isEmpty, list.idle.isEmpty {
                    Text("Apps appear here as they connect.").foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(list.active) { AppRow(route: $0, trunk: state.trunk, expanded: $expanded) }
                    }
                }
                if !list.idle.isEmpty {
                    DisclosureGroup("Idle (\(list.idle.count))") {
                        VStack(spacing: 8) {
                            ForEach(list.idle) { AppRow(route: $0, trunk: state.trunk, expanded: $expanded) }
                        }
                        .padding(.top, 8)
                    }
                }
                ForEach(list.excepted) { ExceptedRow(app: $0) }
                if let error = model.errors[.circuit] ?? model.errors[.exceptions] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .navigationTitle("Route")
    }
}

/// One app: icon, name, its middle → exit; click for details and actions.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    let route: AppRoute
    let trunk: Trunk
    @Binding var expanded: String?

    private var isOpen: Bool { expanded == route.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: AppInfo.icon(route.app)).resizable().frame(width: 24, height: 24)
                Text(AppInfo.name(route.app))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                MetroLine(stops: MetroLine.Stop.tail(route), lit: true, compact: true)
                Text("\(route.middle.flag) → \(route.exit.flag)")
                    .font(.callout)
                    .accessibilityIdentifier("row.exit.\(route.id)")
                    .accessibilityLabel(route.exit.address)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy) { expanded = isOpen ? nil : route.id } }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("route.row.\(route.id)")

            if isOpen {
                MetroLine(stops: MetroLine.Stop.full(trunk, route), lit: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Middle").foregroundStyle(.secondary)
                        Text("\(route.middle.nickname) · \(route.middle.address)")
                    }
                    GridRow {
                        Text("Exit").foregroundStyle(.secondary)
                        Text("\(route.exit.nickname) · \(route.exit.address)")
                    }
                    GridRow {
                        Text("Connections").foregroundStyle(.secondary)
                        Text("\(route.connections)")
                    }
                }
                .font(.caption.monospaced())
                HStack {
                    Button("New circuit", action: newCircuit)
                        .accessibilityIdentifier("circuit.\(route.id)")
                    Button("Exclude from Tor", action: exclude)
                        .accessibilityIdentifier("exclude.\(route.id)")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contextMenu {
            Button("New circuit", action: newCircuit)
            Button("Exclude from Tor", action: exclude)
        }
    }

    private func newCircuit() {
        let app = route.app
        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
    }

    private func exclude() {
        let app = route.app
        Task { await model.perform(.exceptions) { try await $0.addException(app) } }
    }
}

/// An excepted app at the end of the Route list: dimmed, marked direct.
struct ExceptedRow: View {
    let app: AppID

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 24, height: 24)
            Text(AppInfo.name(app)).font(.body.weight(.semibold))
            Spacer()
            Text("direct").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(12)
        .opacity(0.6)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path macos/Packages/TortugaUI`
Expected: `Build complete!` with no warnings.

- [ ] **Step 3: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): Route screen with a trunk and a row per app" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Bridges screen

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/BridgesView.swift`

- [ ] **Step 1: Write the Bridges screen**

`macos/Packages/TortugaUI/Sources/TortugaUI/BridgesView.swift`:

```swift
import SwiftUI
import TortugaKit

struct BridgesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("A bridge hides that you use Tor. Pick one if Tor is blocked where you are.")
                    .foregroundStyle(.secondary)
                BridgeCard(kind: nil)
                ForEach(BridgeKind.allCases, id: \.self) { BridgeCard(kind: $0) }
                if let error = model.errors[.bridges] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .navigationTitle("Bridges")
    }
}

/// One choice: None, Snowflake, obfs4 or WebTunnel. The selected obfs4 or
/// WebTunnel card takes pasted lines, marks bad ones as they're typed, and
/// can get lines from bridges.torproject.org.
struct BridgeCard: View {
    @Environment(AppModel.self) private var model
    let kind: BridgeKind?
    @State private var draft = ""
    @State private var fetching = false

    private var selected: Bool { model.state.bridges.selected == kind }

    private var blurb: String {
        switch kind {
        case nil: "Connect to Tor directly."
        case .snowflake: "Built in. Works in most places."
        case .obfs4: "Paste lines from bridges.torproject.org, or get them here."
        case .webtunnel: "Looks like ordinary HTTPS. Paste lines, or get them here."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: select) {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.route : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind?.title ?? "None").font(.headline)
                            Text(blurb).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bridge.\(kind?.rawValue ?? "none")")
                Spacer()
                if let kind, kind.needsLines {
                    Text("\(model.state.bridges.saved(kind).count) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bridges.\(kind.rawValue).count")
                }
            }
            if let kind, kind.needsLines, selected {
                let parsed = BridgeLines.parse(draft, for: kind)
                TextEditor(text: $draft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                    .accessibilityIdentifier("bridges.\(kind.rawValue).lines")
                ForEach(parsed.errors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("bridges.error")
                }
                HStack {
                    Button("Save") { save(parsed.lines, kind) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.route)
                        .disabled(parsed.lines.isEmpty || !parsed.errors.isEmpty)
                        .accessibilityIdentifier("bridges.\(kind.rawValue).save")
                    Button(fetching ? "Getting…" : "Get lines") { fetch(kind) }
                        .buttonStyle(.glass)
                        .disabled(fetching)
                }
                if let error = model.errors[.fetch] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .glassEffect(selected ? .regular.tint(Color.route.opacity(0.15)) : .regular, in: .rect(cornerRadius: 18))
    }

    private func select() {
        let kind = kind
        Task { await model.perform(.bridges) { try await $0.selectBridge(kind) } }
    }

    private func save(_ lines: [String], _ kind: BridgeKind) {
        Task {
            await model.perform(.bridges) { try await $0.saveBridgeLines(lines, for: kind) }
            if model.errors[.bridges] == nil { draft = "" }
        }
    }

    private func fetch(_ kind: BridgeKind) {
        Task {
            fetching = true
            if let lines = await model.fetchLines(kind) {
                await model.perform(.bridges) { try await $0.saveBridgeLines(lines, for: kind) }
            }
            fetching = false
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path macos/Packages/TortugaUI`
Expected: `Build complete!` with no warnings.

- [ ] **Step 3: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): Bridges screen" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Exceptions and Downloads screens

**Files:**
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/ExceptionsView.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/DownloadsView.swift`

- [ ] **Step 1: Write the Exceptions screen**

`macos/Packages/TortugaUI/Sources/TortugaUI/ExceptionsView.swift`:

```swift
import SwiftUI
import TortugaKit
import UniformTypeIdentifiers

/// Apps that bypass Tor, with a plain warning about what that means.
struct ExceptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.state.exceptions.isEmpty {
                    Text("No exceptions: every app goes through Tor.").foregroundStyle(.secondary)
                }
                ForEach(model.state.exceptions) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 22, height: 22)
                        Text(AppInfo.name(app))
                        Spacer()
                        Button {
                            Task { await model.perform(.exceptions) { try await $0.removeException(app) } }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("remove.\(app.id)")
                    }
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("exception.\(app.id)")
                }
                Button { choosing = true } label: { Label("Add App…", systemImage: "plus") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("exceptions.add")
                Text("These apps connect directly. Sites they reach see your IP address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.errors[.exceptions] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result, let app = AppInfo.id(forAppAt: url) else { return }
            Task { await model.perform(.exceptions) { try await $0.addException(app) } }
        }
        .navigationTitle("Exceptions")
    }
}
```

- [ ] **Step 2: Write the Downloads screen**

`macos/Packages/TortugaUI/Sources/TortugaUI/DownloadsView.swift`:

```swift
import SwiftUI
import TortugaKit

/// Torrents: drop a .torrent file or a magnet link on the screen to add one.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if model.state.downloads.isEmpty {
                    Text("Drop a .torrent file or a magnet link here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(model.state.downloads) { DownloadRow(download: $0) }
                if let error = model.errors[.downloads] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Torrents don't go through Tor: other people in the swarm see your IP address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                let source: DownloadSource = url.isFileURL ? .file(url) : .magnet(url.absoluteString)
                Task { await model.perform(.downloads) { try await $0.addDownload(source) } }
            }
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.route, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
            }
        }
        .navigationTitle("Downloads")
    }
}

struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let download: Download

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(download.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                controls
            }
            ProgressView(value: download.done)
                .tint(download.state == .sharing ? Color.bridge : Color.route)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: download.size, countStyle: .file)
        let percent = Int(download.done * 100)
        switch download.state {
        case .downloading: return "\(percent)% of \(size) · ↓ \(rate(download.downRate))"
        case .sharing: return "Sharing · ↑ \(rate(download.upRate)) · stops at ratio 1.0"
        case .paused: return "Paused at \(percent)% of \(size)"
        case .done: return "Done · \(size)"
        case .failed: return download.error ?? "Failed"
        }
    }

    private func rate(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s"
    }

    @ViewBuilder
    private var controls: some View {
        let id = download.id
        HStack(spacing: 6) {
            if download.state == .downloading || download.state == .sharing {
                command("pause.fill", "Pause") { try await $0.pauseDownload(id) }
            }
            if download.state == .paused {
                command("play.fill", "Resume") { try await $0.resumeDownload(id) }
            }
            command("xmark", "Remove") { try await $0.removeDownload(id) }
        }
    }

    private func command(_ symbol: String, _ label: String,
                         _ action: @escaping @Sendable (any TortugaEngine) async throws -> Void) -> some View {
        Button {
            Task { await model.perform(.downloads, action) }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build --package-path macos/Packages/TortugaUI`
Expected: `Build complete!` with no warnings.

- [ ] **Step 4: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): Exceptions and Downloads screens" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Window, first run, menu bar panel, settings, previews

**Files:**
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/MainWindow.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/FirstRunView.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/MenuPanel.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/SettingsView.swift`
- Create: `macos/Packages/TortugaUI/Sources/TortugaUI/Previews.swift`

- [ ] **Step 1: Add the window to MainWindow.swift**

Append to `macos/Packages/TortugaUI/Sources/TortugaUI/MainWindow.swift`:

```swift
/// The window: a glass sidebar of screens, Direct / Tor in the toolbar, and
/// the first-run card until it's dismissed.
public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didShowWelcome") private var didShowWelcome = false

    public init() {}

    public var body: some View {
        let selection = Binding<SidebarSection?>(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityIdentifier("sidebar.\(section.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.section {
            case .route: RouteView()
            case .bridges: BridgesView()
            case .exceptions: ExceptionsView()
            case .downloads: DownloadsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ModeSwitch() }
        }
        .frame(minWidth: 700, minHeight: 480)
        .sheet(isPresented: Binding(get: { !didShowWelcome }, set: { if !$0 { didShowWelcome = true } })) {
            FirstRunView { didShowWelcome = true }
        }
    }
}
```

- [ ] **Step 2: Write the first-run card**

`macos/Packages/TortugaUI/Sources/TortugaUI/FirstRunView.swift`:

```swift
import SwiftUI

/// Shown once: what Tortuga does, what it doesn't, and the one permission
/// macOS will ask for.
struct FirstRunView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Welcome to Tortuga", systemImage: "tortoise.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.route)
            point("network",
                  "Tortuga sends every app on this Mac through Tor, each app on its own circuit. Sites see a Tor exit, not your IP address.")
            point("person.crop.circle.badge.exclamationmark",
                  "It hides your IP. It doesn't make you anonymous: apps you're signed in to, like iCloud, Telegram or mail, still say who you are. It is not Tor Browser.")
            point("lock.shield",
                  "macOS will ask you once to allow Tortuga's network extension. Until Tor is ready, Tortuga holds traffic back instead of letting it out directly.")
            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.glassProminent)
                    .tint(Color.route)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome.continue")
            }
        }
        .padding(28)
        .frame(width: 470)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

- [ ] **Step 3: Write the menu bar panel, front-app tracker and icon**

`macos/Packages/TortugaUI/Sources/TortugaUI/MenuPanel.swift`:

```swift
import AppKit
import SwiftUI
import TortugaKit

/// The app in front, other than Tortuga itself.
@MainActor @Observable
final class FrontApp {
    private(set) var app: AppID?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(running) }
        }
    }

    private func update(_ running: NSRunningApplication?) {
        guard let running, let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        app = AppID(id, path: running.bundleURL?.path, name: running.localizedName)
    }
}

/// The menu bar panel: switch, status, the front app's route, actions.
public struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var front = FrontApp()

    public init() {}

    public var body: some View {
        let state = model.state
        let app = front.app
        let route = app.flatMap { app in state.apps.first { $0.app == app } }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tortuga").font(.headline)
                Spacer()
                ModeSwitch()
            }
            StatusLine()
            if let app {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppInfo.name(app)).font(.subheadline.weight(.semibold))
                    if let route {
                        MetroLine(stops: MetroLine.Stop.full(state.trunk, route), lit: true)
                        Text("Exit \(route.exit.address) · \(route.exit.country)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else if state.exceptions.contains(app) {
                        Text("Connects directly: it's an exception.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No traffic from \(AppInfo.name(app)) yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button("New circuit") {
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

/// The menu bar icon for a status.
public struct MenuBarLabel: View {
    let status: Status

    public init(status: Status) { self.status = status }

    public var body: some View {
        switch status {
        case .off: Image(systemName: "tortoise")
        case .starting: Image(systemName: "tortoise.fill").symbolEffect(.pulse)
        case .on: Image(systemName: "tortoise.fill")
        case .blocked, .failed: Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
```

- [ ] **Step 4: Write Settings**

`macos/Packages/TortugaUI/Sources/TortugaUI/SettingsView.swift`:

```swift
import AppKit
import ServiceManagement
import SwiftUI
import TortugaKit

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
            #if DEBUG
            Tab("Demo", systemImage: "ladybug") { DemoSettings() }
            #endif
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage("showInDock") private var showInDock = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show in Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, on in NSApp.setActivationPolicy(on ? .regular : .accessory) }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

struct DownloadSettings: View {
    @AppStorage("downloadsFolder") private var folder =
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Tortuga").path

    var body: some View {
        Form {
            LabeledContent("Downloads folder") {
                HStack {
                    Text(folder).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: choose)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tortoise.fill").font(.system(size: 44)).foregroundStyle(Color.route)
            Text("Tortuga").font(.title2.weight(.bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Hides your IP. Not Tor Browser.")
            Link("github.com/legenki/tortuga", destination: URL(string: "https://github.com/legenki/tortuga")!)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
/// Debug builds only: swap the DemoEngine scenario.
struct DemoSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("scenario") private var scenario = Scenario.normal.rawValue

    var body: some View {
        Form {
            Picker("Scenario", selection: $scenario) {
                ForEach(Scenario.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .onChange(of: scenario) { _, name in
                model.replace(engine: DemoEngine.running(Scenario(rawValue: name) ?? .normal))
            }
        }
        .formStyle(.grouped)
    }
}
#endif
```

- [ ] **Step 5: Write previews**

`macos/Packages/TortugaUI/Sources/TortugaUI/Previews.swift`:

```swift
import SwiftUI
import TortugaKit

/// Hosts a view on a running DemoEngine, with Tor switched on if asked.
struct PreviewHost<Content: View>: View {
    @State private var model: AppModel
    private let tor: Bool
    private let content: Content

    init(_ scenario: Scenario, tor: Bool = true, @ViewBuilder content: () -> Content) {
        _model = State(initialValue: AppModel(engine: DemoEngine.running(scenario)))
        self.tor = tor
        self.content = content()
    }

    var body: some View {
        content
            .environment(model)
            .task {
                if tor { await model.perform(.mode) { try await $0.setMode(.tor) } }
            }
    }
}

#Preview("Window, normal") {
    PreviewHost(.normal) { MainWindow() }.frame(width: 760, height: 540)
}

#Preview("Route, many apps") {
    PreviewHost(.manyApps) { RouteView() }.frame(width: 600, height: 640)
}

#Preview("Route, Tor dies") {
    PreviewHost(.torDies) { RouteView() }.frame(width: 600, height: 400)
}

#Preview("Bridges, bridge fails") {
    PreviewHost(.bridgeFails) { BridgesView() }.frame(width: 600, height: 640)
}

#Preview("Downloads") {
    PreviewHost(.normal, tor: false) { DownloadsView() }.frame(width: 600, height: 360)
}

#Preview("Menu panel") {
    PreviewHost(.normal) { MenuPanel() }
}

#Preview("First run") {
    FirstRunView {}
}
```

- [ ] **Step 6: Build and run the package tests**

Run: `swift build --package-path macos/Packages/TortugaUI && swift test --package-path macos/Packages/TortugaUI`
Expected: `Build complete!`, all tests pass, no warnings.

- [ ] **Step 7: Commit**

```bash
git add macos/Packages/TortugaUI
git commit -m "feat(macos): window, menu bar panel, settings, first run and previews" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: App target and Xcode project

**Files:**
- Create: `macos/project.yml`
- Create: `macos/Config/Base.xcconfig`
- Create: `macos/Local.xcconfig.example`
- Create: `macos/Tortuga/TortugaApp.swift`
- Create: `macos/TortugaAppUITests/TortugaAppUITests.swift` (a placeholder test, filled in by Task 15)

- [ ] **Step 1: Write the signing config**

`macos/Config/Base.xcconfig`:

```
// Signing defaults: sign to run locally. Local.xcconfig (not in git) sets
// your team for Developer ID builds; copy it from Local.xcconfig.example.
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
DEVELOPMENT_TEAM =
#include? "../Local.xcconfig"
```

`macos/Local.xcconfig.example`:

```
// Copy to macos/Local.xcconfig (ignored by git) and put in your team ID
// (developer.apple.com → Membership).
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = ABCDE12345
```

- [ ] **Step 2: Write the project spec**

`macos/project.yml`:

```yaml
name: Tortuga
options:
  bundleIdPrefix: org.tortuga
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
packages:
  TortugaKit:
    path: Packages/TortugaKit
  TortugaUI:
    path: Packages/TortugaUI
targets:
  Tortuga:
    type: application
    platform: macOS
    sources: [Tortuga]
    dependencies:
      - package: TortugaKit
      - package: TortugaUI
    info:
      path: Tortuga/Info.plist
      properties:
        CFBundleDisplayName: Tortuga
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSUIElement: true
        LSApplicationCategoryType: public.app-category.utilities
        NSHumanReadableCopyright: Tortuga contributors
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.tortuga.app
        PRODUCT_NAME: Tortuga
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
  TortugaAppUITests:
    type: bundle.ui-testing
    platform: macOS
    sources: [TortugaAppUITests]
    dependencies:
      - target: Tortuga
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.tortuga.app.uitests
        SWIFT_VERSION: "6.0"
        TEST_TARGET_NAME: Tortuga
schemes:
  Tortuga:
    build:
      targets:
        Tortuga: all
        TortugaAppUITests: [test]
    test:
      targets:
        - TortugaAppUITests
```

`Tortuga/Info.plist` is written by XcodeGen from `info.properties`. Add
`macos/Tortuga/Info.plist` to `.gitignore` under the macOS block, because it
is generated.

- [ ] **Step 3: Write the app**

`macos/Tortuga/TortugaApp.swift`:

```swift
import AppKit
import SwiftUI
import TortugaKit
import TortugaUI

@main
struct TortugaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(engine: DemoEngine.running(TortugaApp.scenario))

    /// `-scenario <name>` on the command line, or the Demo tab's choice.
    static var scenario: Scenario {
        UserDefaults.standard.string(forKey: "scenario").flatMap(Scenario.init(rawValue:)) ?? .normal
    }

    /// The window opens at launch the first time (for the welcome card), or
    /// when asked with `-openWindowAtLaunch YES` (UI tests).
    private static var openWindowAtLaunch: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: "didShowWelcome") || defaults.bool(forKey: "openWindowAtLaunch")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            MenuBarLabel(status: model.state.status)
        }
        .menuBarExtraStyle(.window)

        Window("Tortuga", id: "main") {
            MainWindow().environment(model)
        }
        .defaultLaunchBehavior(Self.openWindowAtLaunch ? .presented : .suppressed)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Runs as a menu bar app (no Dock icon) unless Settings says otherwise.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
```

- [ ] **Step 4: Add a placeholder UI test so the target builds**

`macos/TortugaAppUITests/TortugaAppUITests.swift`:

```swift
import XCTest

final class TortugaAppUITests: XCTestCase {
    func testLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-didShowWelcome", "YES", "-openWindowAtLaunch", "YES", "-showInDock", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mode.tor"].firstMatch.waitForExistence(timeout: 10))
    }
}
```

- [ ] **Step 5: Generate the project, build it, run it**

Run:

```bash
cd macos && xcodegen generate && xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build build | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

Then: `open macos/build/Build/Products/Debug/Tortuga.app`

Expected: the first-run card opens in the window, and a tortoise appears in
the menu bar. Click Continue, then Tor. The status goes "Connecting…" →
"Tor on via Snowflake", and Safari, Telegram, Slack and Music appear one by
one. Mail is dimmed at the bottom with "direct". Quit from the menu bar panel.

- [ ] **Step 6: Run the placeholder UI test**

Run: `cd macos && xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build | tail -5`
Expected: `** TEST SUCCEEDED **`. The first run may ask for Accessibility or
Automation access for Xcode's test runner; allow it in System Settings.

- [ ] **Step 7: Commit**

```bash
git add .gitignore macos/project.yml macos/Config macos/Local.xcconfig.example macos/Tortuga/TortugaApp.swift macos/TortugaAppUITests
git commit -m "feat(macos): the Tortuga app target, generated with XcodeGen" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: UI tests for the key paths

**Files:**
- Modify: `macos/TortugaAppUITests/TortugaAppUITests.swift` (replace the whole file)

- [ ] **Step 1: Write the tests**

`macos/TortugaAppUITests/TortugaAppUITests.swift`:

```swift
import XCTest

final class TortugaAppUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-scenario", scenario, "-didShowWelcome", "YES",
                               "-openWindowAtLaunch", "YES", "-showInDock", "YES"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 15) {
        let found = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        wait(for: [found], timeout: timeout)
    }

    func testTorOnAppsAppearAndNewCircuitChangesTheExit() {
        let app = launch("normal")
        element(app, "mode.tor").click()
        waitFor(element(app, "status"), labelContaining: "Tor on")
        let row = element(app, "route.row.com.apple.Safari")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let exit = element(app, "row.exit.com.apple.Safari")
        let before = exit.label
        row.click()
        element(app, "circuit.com.apple.Safari").click()
        let changed = expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: exit)
        wait(for: [changed], timeout: 5)
    }

    func testTorDiesThenRestartBringsItBack() {
        let app = launch("torDies")
        element(app, "mode.tor").click()
        waitFor(element(app, "status"), labelContaining: "Tor on")
        waitFor(element(app, "status"), labelContaining: "traffic is blocked")
        element(app, "restart").click()
        waitFor(element(app, "status"), labelContaining: "Tor on")
    }

    func testAnExceptionCanBeAddedAndRemoved() {
        let app = launch("normal")
        element(app, "mode.tor").click()
        let row = element(app, "route.row.com.apple.Safari")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        element(app, "exclude.com.apple.Safari").click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        element(app, "sidebar.exceptions").click()
        let entry = element(app, "exception.com.apple.Safari")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        element(app, "remove.com.apple.Safari").click()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
    }

    func testABadObfs4LineIsMarkedAndAGoodOneSaved() {
        let app = launch("normal")
        element(app, "sidebar.bridges").click()
        element(app, "bridge.obfs4").click()
        let lines = element(app, "bridges.obfs4.lines")
        XCTAssertTrue(lines.waitForExistence(timeout: 5))
        lines.click()
        lines.typeText("obfs4 192.0.2.1:443 nope")
        XCTAssertTrue(element(app, "bridges.error").waitForExistence(timeout: 3))
        lines.typeKey("a", modifierFlags: .command)
        lines.typeKey(.delete, modifierFlags: [])
        lines.typeText("obfs4 192.0.2.1:443 " + String(repeating: "A", count: 40) + " cert=x iat-mode=0")
        XCTAssertTrue(element(app, "bridges.error").waitForNonExistence(timeout: 3))
        element(app, "bridges.obfs4.save").click()
        waitFor(element(app, "bridges.obfs4.count"), labelContaining: "1 saved", timeout: 5)
    }
}
```

- [ ] **Step 2: Run them**

Run: `cd macos && xcodegen generate && xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build | tail -15`
Expected: `** TEST SUCCEEDED **` with 4 tests.

If a test can't find an element, print the hierarchy before changing the
test. Add `print(app.debugDescription)` before the failing line, find how
the identifier shows up (button, group, staticText), then fix the
accessibility modifier in the view rather than the test's identifiers.

- [ ] **Step 3: Commit**

```bash
git add macos/TortugaAppUITests
git commit -m "test(macos): UI tests for Tor on, Tor dies, exceptions and bridge lines" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: CI job and docs

**Files:**
- Modify: `.github/workflows/release.yml` (add a `macos-app` job after the `extension` job)
- Create: `macos/README.md`
- Modify: `README.md` (add a short section before "## Release" or at the end of the install part)

- [ ] **Step 1: Add the CI job**

In `.github/workflows/release.yml`, under `jobs:`, after the `extension` job
and before `release:`, add:

```yaml
  macos-app:
    # The native app (macos/). Not needed by the release job yet.
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - run: brew install xcodegen
      - name: Package tests
        run: |
          swift test --package-path macos/Packages/TortugaKit
          swift test --package-path macos/Packages/TortugaUI
      - name: Build and UI tests
        working-directory: macos
        run: |
          xcodegen generate
          xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build
```

Leave `release.needs` unchanged.

- [ ] **Step 2: Write macos/README.md**

`macos/README.md`:

````markdown
# Tortuga for macOS

A native app that will send the whole Mac through Tor
(design: `docs/superpowers/specs/2026-11-09-macos-app-design.md`). This is
part 1: the full interface on `DemoEngine`, a simulated engine. **It does not
use Tor or the network yet.**

## Needs

- macOS 26 or later, Xcode 26 or later
- XcodeGen: `brew install xcodegen`

## Build and run

```sh
cd macos
xcodegen generate                       # writes Tortuga.xcodeproj (not in git)
open Tortuga.xcodeproj                  # or build from the command line:
xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -derivedDataPath build build
open build/Build/Products/Debug/Tortuga.app
```

It runs from the menu bar (a tortoise). The window opens at first launch and
from "Open Tortuga".

To sign with your team, copy `Local.xcconfig.example` to `Local.xcconfig`
and put in your team ID. Without it, builds are signed to run locally.

## Demo scenarios

Debug builds have a Demo tab in Settings (⌘,). You can also launch with
`-scenario <name>`:

| Scenario | What happens |
|---|---|
| `normal` | Tor connects in ~4 s, four apps appear, Mail is an exception |
| `slowBootstrap` | connecting takes 30 s |
| `bridgeFails` | Snowflake never connects; switch to obfs4 ("Get lines") to recover |
| `torDies` | Tor stops 5 s after connecting; Restart brings it back |
| `manyApps` | 30 apps, half of them idle |
| `empty` | Tor on, no apps |

## Tests

```sh
swift test --package-path Packages/TortugaKit
swift test --package-path Packages/TortugaUI
xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build
```
````

- [ ] **Step 3: Mention it in the root README**

In `README.md`, after the "**Uninstalling the helper:**" list and its "Your
downloads are left where they are." line, add:

```markdown
**Native macOS app (in development).** `macos/` holds a native app that will
send the whole Mac through Tor, with a circuit for each app. Right now it runs
on a simulated engine only. See [macos/README.md](macos/README.md).
```

- [ ] **Step 4: Check the workflow parses**

Run: `python3 -I -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('ok')"`
Expected: `ok`. If PyYAML is missing, run
`ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "ok"'`
instead.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml macos/README.md README.md
git commit -m "ci(macos): build and test the native app; docs" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Done when

- `swift test` passes in both packages with no warnings.
- `xcodebuild test` passes all 4 UI tests.
- The app runs from the menu bar. Every screen in the spec's "Part 1" can be
  reached and clicked through, in every scenario, in light and dark mode.
