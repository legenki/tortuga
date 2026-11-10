# Real Tor for the Mac, plan 2: the real extension, XPC and ProxyEngine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switching the app to Tor sends every app on the Mac through Tor,
each on its own circuit. DNS goes through Tor. Nothing leaves directly while
Tor isn't ready. The Route screen shows the real relays.

**Architecture:**
- **Two providers, one core.** The `TortugaProxy` system extension holds a
  transparent proxy and a DNS proxy. Both share one `ProxyCore` actor in
  `TortugaProxyKit`.
- **The helper.** `ProxyCore` runs `tortuga-helper` from the app's bundle in
  /Applications, the only place its sandbox can run it from (spike Q5). It
  publishes routing decisions to a lock-protected `RouteTable` that the
  providers read synchronously.
- **The app.** It talks to the extension over XPC through `ProxyEngine`, a
  `TortugaEngine`. It keeps the user's settings (mode, bridge, lines,
  exceptions) and hands them to the extension two ways:
  - in the provider configuration, so the extension has them from the start;
  - with an XPC `configure` command whenever they change.
- **What can be tested without a system extension** lives in
  `TortugaProxyKit` and is tested there. That covers `ProxyCore`,
  `ProxyEngine`, `DNSAnswerer` and the wire messages.
- **The providers, the relay and the XPC glue** are thin, and the live check
  covers them.

**Tech Stack:** Swift 6, NetworkExtension (NETransparentProxyProvider,
NEDNSProxyProvider), SystemExtensions, NSXPCConnection, Network
(NWConnection), swift-testing.

**Inputs:**
- `docs/superpowers/specs/2026-11-10-macos-real-tor-design.md`;
- `docs/spike-findings.md`, section "macOS system extension";
- plan 1 (`TortugaProxyKit` as built there).

**Conventions:**
- **Directory:** run commands from the repository root unless a step says
  otherwise.
- **Commits:** each message ends with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Branch:** `feat/macos-real-tor`.
- **Installing:** `macos/scripts/install-dev.sh` builds, installs to
  /Applications and opens the app. `macos/Local.xcconfig` (team Y6A9LRQDH7)
  already exists.

---

## Decisions this plan adds to the spec (from the spike)

1. **Where the helper runs from.** The extension runs the helper and
   lyrebird from the app's copy of the extension, in
   `/Applications/Tortuga.app/Contents/Library/SystemExtensions/org.tortuga.app.proxy.systemextension/`.
   The app sends that path in the configuration. If it's missing, Tor can't
   start and the status says to move Tortuga to /Applications.
2. **Where settings live.** The user's settings live in the app
   (UserDefaults) and reach the extension in the provider configuration and
   by XPC. They do not live in an extension store. The extension runs only
   while the proxy is on, and the DNS proxy can't read its own provider
   configuration.
3. **The DNS proxy answers every query itself.** Through Tor, empty, or
   SERVFAIL; it never returns `false`, because that drops the query. DNS over
   TCP flows are closed, and resolvers retry over UDP.
4. **Local networks never reach the transparent proxy.** It excludes
   loopback, private, link-local and multicast networks in its settings, so
   AirDrop, printers and mDNS keep working. UDP flows elsewhere are closed.
5. **Our own programs.** The helper and lyrebird are recognised by their
   signing identifiers `tortuga-helper` and `lyrebird`. Their traffic goes
   out directly.
6. **XPC.** Only the Tortuga app may connect: the extension sets a
   code-signing requirement on each connection.

---

## File map

| File | Responsibility |
|---|---|
| `macos/Packages/TortugaKit/Sources/TortugaKit/Models.swift` | `Codable` models, `downloadsAvailable`, `Status.allowExtensionReason` |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/ProxyMessages.swift` | `ProxyConfiguration`, `ExtensionState`, `ExtensionCommand`, `ExtensionReply`, `Wire` |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/RouteTable.swift` | the providers' synchronous view of routing |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/ProxyCore.swift` | the extension's engine: helper lifecycle, state, activity, resolve |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/ProcessLauncher.swift` | starts the real helper for `ProxyCore` |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/DNSAnswerer.swift` | one DNS query → one answer |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift` | the app's `TortugaEngine` over `ProxyControl` |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/Settings.swift` | `StoredSettings`, `SettingsStore`, `DefaultsSettingsStore` |
| `…/TortugaProxyKit/Sources/TortugaProxyKit/XPC.swift` | `@objc` XPC protocols and `XPCLink` (app side) |
| `…/TortugaProxyKit/Tests/TortugaProxyKitTests/…` | tests for the above |
| `macos/TortugaProxy/Shared.swift` | the one `ProxyCore` and `NameCache` of the extension process |
| `macos/TortugaProxy/TransparentProxy.swift` | TCP and UDP flows |
| `macos/TortugaProxy/TCPRelay.swift` | one flow ↔ the helper's SOCKS port |
| `macos/TortugaProxy/DNSProxy.swift` | DNS flows |
| `macos/TortugaProxy/XPCServer.swift` | the extension's XPC listener |
| `macos/TortugaProxy/main.swift` | starts XPC and the providers |
| `macos/Tortuga/SystemProxyControl.swift` | activation, NE managers, XPC connect |
| `macos/Tortuga/TortugaApp.swift` | real engine by default, `DemoEngine` with `-scenario` |
| `macos/Packages/TortugaUI/Sources/TortugaUI/{StatusLine,DownloadsView,SettingsView}.swift` | Open System Settings button; "later version" downloads; Demo "real" choice |
| `macos/scripts/live-check.sh` | the live check |

---

### Task 1: Write the decisions into the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-11-10-macos-real-tor-design.md`

- [ ] **Step 1:** Add the section above ("Decisions this plan adds to the
  spec") to the spec, under its own heading
  `## Changes after the spike (2026-11-10)`. Copy decisions 1–6 as they are.
- [ ] **Step 2:** In the spec's "Processes" block:
  - replace `Store: mode, bridge, bridge lines, exceptions (a plist in the extension's container)`
    with `Settings arrive from the app (provider configuration + XPC configure)`;
  - replace `runs Contents/Helpers/tortuga-helper (+ pt/lyrebird)` with
    `runs tortuga-helper (+ lyrebird) from the app's bundle in /Applications`.
- [ ] **Step 3:** In the "Decisions" table, set "Where settings live" to
  `In the app (UserDefaults); sent to the extension in the provider configuration and by XPC`.
- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-11-10-macos-real-tor-design.md
git commit -m "docs(macos): spec changes after the system-extension spike" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: TortugaKit models travel over XPC

**Files:**
- Modify: `macos/Packages/TortugaKit/Sources/TortugaKit/Models.swift`
- Create: `macos/Packages/TortugaKit/Tests/TortugaKitTests/CodableTests.swift`

- [ ] **Step 1: Write the failing test**

`macos/Packages/TortugaKit/Tests/TortugaKitTests/CodableTests.swift`:

```swift
import Foundation
import Testing
@testable import TortugaKit

@Test func engineStateRoundTrips() throws {
    var state = EngineState()
    state.mode = .tor
    state.status = .starting(step: "Loading the network", progress: 0.4)
    state.trunk = Trunk(bridge: .snowflake, guardRelay: Relay(nickname: "g", country: "DE", address: "1.1.1.1"))
    state.apps = [AppRoute(app: AppID("com.apple.Safari", name: "Safari"),
                           middle: Relay(nickname: "m", country: "NL", address: "2.2.2.2"),
                           exit: Relay(nickname: "e", country: "SE", address: "3.3.3.3"),
                           connections: 2, lastActive: Date(timeIntervalSince1970: 1_800_000_000))]
    state.bridges = BridgeSettings(selected: .obfs4, lines: [.obfs4: ["Bridge obfs4 x"]])
    state.exceptions = [AppID("com.apple.mail")]
    state.downloadsAvailable = false
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(EngineState.self, from: data) == state)
}

@Test func theAllowMessageIsShared() {
    #expect(Status.allowExtensionReason == "Allow Tortuga's network extension in System Settings")
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path macos/Packages/TortugaKit 2>&1 | grep -E "error:" | head -3`
Expected: errors such as `type 'EngineState' does not conform to protocol 'Encodable'`.

- [ ] **Step 3: Implement**

In `Models.swift`:
- **`Codable`:** add it to the conformance lists of `Mode`, `Status`,
  `Relay`, `AppID`, `Trunk`, `AppRoute`, `BridgeSettings`, `DownloadState`,
  `Download` and `EngineState`. For example, `public enum Mode: String,
  Sendable, Equatable, CaseIterable, Codable`.
- **`downloadsAvailable`:** in `EngineState`, after
  `public var downloads: [Download] = []`, add:

```swift
    /// False with the real engine until downloads move into the app (part 4).
    public var downloadsAvailable = true
```

- **`allowExtensionReason`:** after the `Status` enum, add:

```swift
extension Status {
    /// The reason the real engine gives while macOS waits for the user to
    /// allow the network extension; the UI offers to open System Settings.
    public static let allowExtensionReason = "Allow Tortuga's network extension in System Settings"
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes (40).

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaKit
git commit -m "feat(macos): Codable engine models, for XPC" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Wire messages and the route table

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyMessages.swift`
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/RouteTable.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/ProxyMessagesTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/ProxyMessagesTests.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

let sampleConfig = ProxyConfiguration(bridge: .snowflake, lines: [.obfs4: ["Bridge obfs4 x"]],
                                      exceptions: ["com.apple.mail"], helperPath: "/A/helper", ptDir: "/A/pt")

@Test func configurationTravelsInTheProviderConfiguration() throws {
    let dictionary = try sampleConfig.providerConfiguration()
    #expect(ProxyConfiguration(providerConfiguration: dictionary) == sampleConfig)
    #expect(ProxyConfiguration(providerConfiguration: nil) == nil)
    #expect(ProxyConfiguration(providerConfiguration: ["configuration": Data("x".utf8)]) == nil)
}

@Test func commandsRepliesAndStatesRoundTrip() {
    for command in [ExtensionCommand.configure(sampleConfig), .restart, .newCircuit(app: "a"), .newCircuit(app: nil),
                    .fetchBridgeLines(.obfs4)] {
        #expect(Wire.decode(ExtensionCommand.self, Wire.encode(command)) == command)
    }
    for reply in [ExtensionReply.ok, .lines(["l"]), .failure("no")] {
        #expect(Wire.decode(ExtensionReply.self, Wire.encode(reply)) == reply)
    }
    let state = ExtensionState(status: .blocked(reason: "Tor stopped"), trunk: Trunk(bridge: .snowflake, guardRelay: nil), apps: [])
    #expect(Wire.decode(ExtensionState.self, Wire.encode(state)) == state)
    #expect(Wire.decode(ExtensionReply.self, Data("garbage".utf8)) == nil)
}

@Test func theRouteTableHandsOutWhatWasPut() {
    let table = RouteTable()
    #expect(table.snapshot().socksPort == nil)
    #expect(table.snapshot().state.torReady == false)
    #expect(table.snapshot().state.own == ProxyCore.ownIDs)
    table.update(state: RouterState(torReady: true, exceptions: ["x"], own: ProxyCore.ownIDs), socksPort: 9150)
    #expect(table.snapshot().socksPort == 9150)
    #expect(table.snapshot().state.exceptions == ["x"])
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | sort -u | head -3`
Expected: `cannot find 'ProxyConfiguration' in scope`.

- [ ] **Step 3: Implement the messages**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyMessages.swift`:

```swift
import Foundation
import TortugaKit

/// What the extension needs from the app: the user's settings and where
/// the helper is.
public struct ProxyConfiguration: Codable, Sendable, Equatable {
    public var bridge: BridgeKind?
    public var lines: [BridgeKind: [String]]
    /// Signing identifiers of excepted apps.
    public var exceptions: [String]
    /// tortuga-helper in the app's copy of the extension (spike Q5).
    public var helperPath: String
    /// pt/ (lyrebird, pt_config.json) next to it.
    public var ptDir: String

    public init(bridge: BridgeKind?, lines: [BridgeKind: [String]], exceptions: [String], helperPath: String, ptDir: String) {
        self.bridge = bridge
        self.lines = lines
        self.exceptions = exceptions
        self.helperPath = helperPath
        self.ptDir = ptDir
    }

    static let providerKey = "configuration"

    /// For `NETunnelProviderProtocol.providerConfiguration`.
    public func providerConfiguration() throws -> [String: Any] {
        [Self.providerKey: try JSONEncoder().encode(self)]
    }

    public init?(providerConfiguration: [String: Any]?) {
        guard let data = providerConfiguration?[Self.providerKey] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}

/// The part of the UI's state that only the extension knows.
public struct ExtensionState: Codable, Sendable, Equatable {
    public var status: Status
    public var trunk: Trunk
    public var apps: [AppRoute]

    public init(status: Status, trunk: Trunk, apps: [AppRoute]) {
        self.status = status
        self.trunk = trunk
        self.apps = apps
    }

    public static let idle = ExtensionState(status: .off, trunk: Trunk(), apps: [])
}

public enum ExtensionCommand: Codable, Sendable, Equatable {
    case configure(ProxyConfiguration)
    case restart
    /// nil: every app.
    case newCircuit(app: String?)
    case fetchBridgeLines(BridgeKind)
}

public enum ExtensionReply: Codable, Sendable, Equatable {
    case ok
    case lines([String])
    case failure(String)
}

/// JSON over XPC.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
```

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/RouteTable.swift`:

```swift
import Synchronization

/// What the providers read for every flow, synchronously: whether Tor is
/// ready, the exceptions, our own programs, and the helper's SOCKS port.
/// `ProxyCore` keeps it current.
public final class RouteTable: Sendable {
    public struct Snapshot: Sendable {
        public var state: RouterState
        public var socksPort: Int?
    }

    private let box = Mutex(Snapshot(state: RouterState(torReady: false, exceptions: [], own: ProxyCore.ownIDs), socksPort: nil))

    public init() {}

    public func update(state: RouterState, socksPort: Int?) {
        box.withLock { $0 = Snapshot(state: state, socksPort: socksPort) }
    }

    public func snapshot() -> Snapshot { box.withLock { $0 } }
}
```

`RouteTable` refers to `ProxyCore.ownIDs`, which comes in Task 4. Until
then, add this temporary file so the package builds:
`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyCore.swift`:

```swift
public actor ProxyCore {
    /// Signing identifiers of our own programs: their traffic goes out directly.
    public static let ownIDs: Set<String> = ["tortuga-helper", "lyrebird"]
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): messages between app and extension, and the route table" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: ProxyCore, the extension's engine

**Files:**
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/HelperClient.swift` (`terminate`)
- Modify: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/HelperClientTests.swift` (`FakeTransport.terminate`)
- Modify: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyCore.swift` (replace the temporary file)
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProcessLauncher.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/TestSupport.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/ProxyCoreTests.swift`

- [ ] **Step 1: Let a client end its helper**

In `HelperClient.swift`, add `func terminate()` to `HelperTransport`:

```swift
public protocol HelperTransport: Sendable {
    func write(_ data: Data) async throws
    /// Bytes from the helper as they arrive; finishes when it exits.
    var incoming: AsyncStream<Data> { get }
    /// End the helper (its `incoming` then finishes).
    func terminate()
}
```

and inside `HelperClient`, after `request(_:)`:

```swift
    /// End the helper; waiting requests fail with `.gone`.
    public nonisolated func shutdown() {
        transport.terminate()
    }
```

`transport` is a `let` of a `Sendable` type, so a nonisolated method may use
it. In `HelperClientTests.swift`, add to `FakeTransport`:

```swift
    private(set) var terminated = false
    func terminate() {
        lock.withLock { terminated = true }
        close()
    }
```

`ProcessTransport` already has `terminate()`.

- [ ] **Step 2: Write the test support and the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/TestSupport.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

func eventually(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

/// Plays the helper: answers each request of a known type once, by id.
func serve(_ fake: FakeTransport, _ answers: [String: @Sendable (Int) -> String]) -> Task<Void, Never> {
    Task {
        var answered = Set<Int>()
        while !Task.isCancelled {
            for request in fake.requests {
                guard let id = request["id"] as? Int, !answered.contains(id),
                      let type = request["type"] as? String, let make = answers[type] else { continue }
                answered.insert(id)
                fake.send(make(id))
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

let helloAnswer: @Sendable (Int) -> String = { #"{"id":\#($0),"type":"hello","payload":{"protocol":1,"version":"0.2.0","features":["apps"]}}"# }
let readyAnswer: @Sendable (Int) -> String = { #"{"id":\#($0),"type":"tor.ready","payload":{"socksPort":40000}}"# }

final class FakeLauncher: HelperLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeTransport] = []
    private var failing = false

    var transports: [FakeTransport] { lock.withLock { made } }
    func fail() { lock.withLock { failing = true } }

    func launch(helperPath: String, ptDir: String) throws -> any HelperTransport {
        try lock.withLock {
            if failing { throw EngineError("no helper at \(helperPath)") }
            let fake = FakeTransport()
            made.append(fake)
            return fake
        }
    }
}
```

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/ProxyCoreTests.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

private func onCore() async throws -> (ProxyCore, FakeLauncher, Task<Void, Never>) {
    let launcher = FakeLauncher()
    let core = ProxyCore(launcher: launcher, retryDelay: .zero)
    await core.configure(sampleConfig)
    let starting = Task { await core.start() }
    try await eventually { launcher.transports.count == 1 }
    let server = serve(launcher.transports[0], ["hello": helloAnswer, "tor.start": readyAnswer])
    await starting.value
    return (core, launcher, server)
}

@Suite struct ProxyCoreTests {
    @Test func startsTheHelperWithTheBridgeAndGoesOn() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        #expect(await core.current.status == .on)
        let snapshot = core.routes.snapshot()
        #expect(snapshot.state.torReady)
        #expect(snapshot.socksPort == 40000)
        #expect(snapshot.state.exceptions == ["com.apple.mail"])
        let start = try #require(launcher.transports[0].requests.first { $0["type"] as? String == "tor.start" })
        let bridge = (start["payload"] as? [String: Any])?["bridge"] as? [String: Any]
        #expect(bridge?["kind"] as? String == "snowflake")
    }

    @Test func bootstrapProgressShowsUntilReady() async throws {
        let launcher = FakeLauncher()
        let core = ProxyCore(launcher: launcher, retryDelay: .zero)
        await core.configure(sampleConfig)
        let starting = Task { await core.start() }
        try await eventually { launcher.transports.count == 1 }
        let fake = launcher.transports[0]
        let server = serve(fake, ["hello": helloAnswer])
        fake.send(#"{"type":"tor.status","payload":{"phase":"directory","percent":40,"blocked":null}}"#)
        try await eventually { await core.current.status == .starting(step: "Loading the network", progress: 0.4) }
        #expect(core.routes.snapshot().state.torReady == false)
        server.cancel()
        fake.close()
        _ = await starting.value
    }

    @Test func circuitsBecomeRoutesAndFlowsCount() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        await core.flowOpened(app: "com.apple.Safari")
        launcher.transports[0].send(#"{"type":"circuit","payload":{"site":"com.apple.Safari","bridge":"snowflake","hops":[{"role":"bridge","id":"B","addr":null,"country":null},{"role":"middle","id":"M","addr":"2.2.2.2:1","country":"NL"},{"role":"exit","id":"E","addr":"3.3.3.3:1","country":"SE"}]}}"#)
        try await eventually { await core.current.apps.count == 1 }
        let route = await core.current.apps[0]
        #expect(route.app.id == "com.apple.Safari")
        #expect(route.exit.country == "SE")
        #expect(route.connections == 1)
        #expect(await core.current.trunk.bridge == .snowflake)
        await core.flowOpened(app: "com.apple.Safari")
        await core.flowClosed(app: "com.apple.Safari")
        #expect(await core.current.apps[0].connections == 1)
    }

    @Test func aDeadHelperBlocksThenComesBack() async throws {
        let (core, launcher, server) = try await onCore()
        server.cancel()
        launcher.transports[0].close()
        try await eventually { launcher.transports.count == 2 }
        #expect(core.routes.snapshot().state.torReady == false)
        let second = serve(launcher.transports[1], ["hello": helloAnswer, "tor.start": readyAnswer])
        defer { second.cancel() }
        try await eventually { await core.current.status == .on }
    }

    @Test func noHelperMeansMoveToApplications() async throws {
        let launcher = FakeLauncher()
        launcher.fail()
        let core = ProxyCore(launcher: launcher, retryDelay: .zero)
        await core.configure(sampleConfig)
        await core.start()
        #expect(await core.current.status == .failed(reason: "Tortuga isn't in /Applications: move it there, then Restart"))
    }

    @Test func commandsNeedTor() async {
        let core = ProxyCore(launcher: FakeLauncher(), retryDelay: .zero)
        await #expect(throws: EngineError("Tor isn't on")) { try await core.newCircuit(app: nil) }
        await #expect(throws: EngineError("Tor isn't on")) { try await core.resolve("example.com") }
    }

    @Test func resolveAndNewCircuitGoToTheHelper() async throws {
        let (core, launcher, server) = try await onCore()
        server.cancel()
        let fake = launcher.transports[0]
        let more = serve(fake, ["tor.resolve": { #"{"id":\#($0),"type":"resolved","payload":{"addresses":["93.184.215.14"]}}"# },
                                "tor.newCircuit": { #"{"id":\#($0),"type":"ok"}"# }])
        defer { more.cancel() }
        #expect(try await core.resolve("example.com") == ["93.184.215.14"])
        try await core.newCircuit(app: "com.apple.Safari")
        #expect(fake.requests.contains { ($0["payload"] as? [String: Any])?["site"] as? String == "com.apple.Safari" })
    }

    @Test func stoppingEndsTheHelper() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        await core.stop()
        #expect(await core.current == .idle)
        #expect(launcher.transports[0].terminated)
        #expect(core.routes.snapshot().socksPort == nil)
    }

    @Test func aNewBridgeRestartsTheHelper() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        var changed = sampleConfig
        changed.bridge = nil
        let configuring = Task { await core.configure(changed) }
        try await eventually { launcher.transports.count == 2 }
        let second = serve(launcher.transports[1], ["hello": helloAnswer, "tor.start": readyAnswer])
        defer { second.cancel() }
        await configuring.value
        let start = try #require(launcher.transports[1].requests.first { $0["type"] as? String == "tor.start" })
        #expect(((start["payload"] as? [String: Any])?["bridge"] as? [String: Any])?["kind"] as? String == "none")
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | sort -u | head -3`
Expected: `cannot find type 'HelperLauncher' in scope`, or
`value of type 'ProxyCore' has no member …`.

- [ ] **Step 4: Implement ProxyCore**

Replace `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyCore.swift` with:

```swift
import Foundation
import TortugaKit

/// Starts the helper process; a fake in tests.
public protocol HelperLauncher: Sendable {
    func launch(helperPath: String, ptDir: String) throws -> any HelperTransport
}

/// The extension's engine. It runs the helper, keeps Tor's state and each
/// app's route and activity, resolves names, and keeps `routes` current for
/// the providers. One per extension process, shared by both providers.
public actor ProxyCore {
    /// Signing identifiers of our own programs: their traffic goes out directly.
    public static let ownIDs: Set<String> = ["tortuga-helper", "lyrebird"]
    static let maxRetries = 3

    public nonisolated let routes = RouteTable()
    private let launcher: any HelperLauncher
    private let retryDelay: Duration
    private let now: @Sendable () -> Date

    private var config: ProxyConfiguration?
    private var state = ExtensionState.idle
    private var client: HelperClient?
    private var watcher: Task<Void, Never>?
    private var socksPort: Int?
    private var wanted = false
    private var retries = 0
    private var pending: [String: (connections: Int, last: Date)] = [:]
    private var observers: [UUID: AsyncStream<ExtensionState>.Continuation] = [:]

    public init(launcher: any HelperLauncher, retryDelay: Duration = .seconds(2), now: @escaping @Sendable () -> Date = { .now }) {
        self.launcher = launcher
        self.retryDelay = retryDelay
        self.now = now
    }

    public var current: ExtensionState { state }

    /// The current state first, then every change.
    public func states() -> AsyncStream<ExtensionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ExtensionState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.yield(state)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.forget(id) } }
        return stream
    }

    // MARK: Commands

    /// New settings. A different bridge, bridge lines or helper restarts Tor.
    public func configure(_ new: ProxyConfiguration) async {
        let old = config
        config = new
        publishRoutes()
        guard wanted else { return }
        if client == nil || old?.bridge != new.bridge || old?.lines != new.lines || old?.helperPath != new.helperPath {
            await startHelper()
        }
    }

    /// The proxy is on: run Tor.
    public func start() async {
        wanted = true
        retries = 0
        await startHelper()
    }

    /// The proxy is off: stop Tor.
    public func stop() async {
        wanted = false
        stopHelper()
        state = .idle
        pending = [:]
        publishRoutes()
        publish()
    }

    public func restart() async {
        retries = 0
        await startHelper()
    }

    public func newCircuit(app: String?) async throws {
        guard let client, socksPort != nil else { throw EngineError("Tor isn't on") }
        let sites = app.map { [$0] } ?? state.apps.map(\.app.id)
        for site in sites { _ = try await client.request(.newCircuit(site: site)) }
    }

    public func resolve(_ name: String) async throws -> [String] {
        guard let client, socksPort != nil else { throw EngineError("Tor isn't on") }
        guard case .resolved(let addresses) = try await client.request(.resolve(name)) else { return [] }
        return addresses
    }

    public func fetchBridgeLines(_ kind: BridgeKind) async throws -> [String] {
        guard let client else { throw EngineError("Switch to Tor to get bridge lines") }
        guard case .bridgeLines(let lines) = try await client.request(.fetchBridges(kind: kind.rawValue)) else { return [] }
        return lines
    }

    // MARK: Activity

    public func flowOpened(app: String) {
        let at = now()
        if let i = state.apps.firstIndex(where: { $0.app.id == app }) {
            state.apps[i].connections += 1
            state.apps[i].lastActive = at
            publish()
        } else {
            let before = pending[app]?.connections ?? 0
            pending[app] = (before + 1, at)
        }
    }

    public func flowClosed(app: String) {
        if let i = state.apps.firstIndex(where: { $0.app.id == app }) {
            state.apps[i].connections = max(0, state.apps[i].connections - 1)
            publish()
        } else if let entry = pending[app] {
            pending[app] = (max(0, entry.connections - 1), entry.last)
        }
    }

    // MARK: The helper

    private func startHelper() async {
        stopHelper()
        guard let config else {
            setStatus(.failed(reason: "Tortuga's settings didn't reach its network extension"))
            return
        }
        let transport: any HelperTransport
        do {
            transport = try launcher.launch(helperPath: config.helperPath, ptDir: config.ptDir)
        } catch {
            setStatus(.failed(reason: "Tortuga isn't in /Applications: move it there, then Restart"))
            return
        }
        let client = HelperClient(transport: transport)
        self.client = client
        setStatus(.starting(step: "Starting Tor", progress: 0))
        let events = client.events
        watcher = Task { [weak self] in
            for await event in events { await self?.handle(event, from: client) }
            await self?.helperGone(client)
        }
        do {
            _ = try await client.request(.hello)
            let lines = config.bridge.map { config.lines[$0] ?? [] } ?? []
            let reply = try await client.request(.start(bridge: StateMapping.helperName(config.bridge), lines: lines))
            guard client === self.client else { return }
            if case .torReady(let port) = reply {
                socksPort = port
                retries = 0
                setStatus(.on)
            }
        } catch HelperError.remote(_, let message) {
            guard client === self.client else { return }
            setStatus(.failed(reason: message))
        } catch {
            // The helper went away; helperGone decides what's next.
        }
    }

    private func stopHelper() {
        watcher?.cancel()
        watcher = nil
        let old = client
        client = nil
        socksPort = nil
        old?.shutdown()
    }

    private func handle(_ event: HelperEvent, from source: HelperClient) {
        guard source === client else { return }
        switch event {
        case .torStatus(let phase, let percent, let blocked):
            guard socksPort == nil else { return }
            setStatus(StateMapping.status(phase: phase, percent: percent, blocked: blocked, bridge: config?.bridge))
        case .circuit(let site, let bridge, let hops):
            var engine = EngineState()
            engine.trunk = state.trunk
            engine.apps = state.apps
            StateMapping.apply(site: site, bridge: bridge, hops: hops, to: &engine, now: now())
            if let i = engine.apps.firstIndex(where: { $0.app.id == site }), let waiting = pending.removeValue(forKey: site) {
                engine.apps[i].connections += waiting.connections
                engine.apps[i].lastActive = waiting.last
            }
            state.trunk = engine.trunk
            state.apps = engine.apps
            publish()
        default:
            break
        }
    }

    private func helperGone(_ gone: HelperClient) async {
        guard gone === client else { return }
        client = nil
        socksPort = nil
        setStatus(.blocked(reason: "Tor stopped"))
        guard wanted, retries < Self.maxRetries else { return }
        retries += 1
        try? await Task.sleep(for: retryDelay)
        if wanted && client == nil { await startHelper() }
    }

    // MARK: State

    private func setStatus(_ status: Status) {
        state.status = status
        if status != .on { state.trunk = status == .off ? Trunk() : state.trunk }
        publishRoutes()
        publish()
    }

    private func publishRoutes() {
        routes.update(state: RouterState(torReady: socksPort != nil && state.status == .on,
                                         exceptions: Set(config?.exceptions ?? []),
                                         own: Self.ownIDs),
                      socksPort: socksPort)
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(state) }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }
}
```

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProcessLauncher.swift`:

```swift
import Foundation

/// Starts the real helper with its data under `dataDirectory` and lyrebird
/// from `ptDir`.
public struct ProcessLauncher: HelperLauncher {
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public func launch(helperPath: String, ptDir: String) throws -> any HelperTransport {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: helperPath])
        }
        return try ProcessTransport(executable: URL(fileURLWithPath: helperPath),
                                    environment: ["TORTUGA_DATA_DIR": dataDirectory.path, "TORTUGA_PT_DIR": ptDir])
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes, no warnings. If `aDeadHelperBlocksThenComesBack`
is flaky, check `helperGone`. It must ignore a client that is no longer
current: `stopHelper()` clears `client` before shutting the old one down.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): ProxyCore runs the helper and keeps the extension's state" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: DNS answers

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/DNSAnswerer.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/DNSAnswererTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/DNSAnswererTests.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

private func query(_ type: UInt16) -> Data {
    var b: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0] + [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
    return Data(b)
}

private func rcode(_ answer: Data?) -> UInt8? { answer.map { $0[3] & 0x0F } }
private func answers(_ answer: Data?) -> Int? { answer.map { Int($0[6]) << 8 | Int($0[7]) } }

@Test func aQueryIsResolvedThroughTorAndRemembered() async {
    let names = NameCache()
    let answer = await DNSAnswerer.answer(query(DNSType.a), torReady: true, names: names) { name in
        #expect(name == "example.com")
        return ["93.184.215.14"]
    }
    #expect(rcode(answer) == 0)
    #expect(answers(answer) == 1)
    #expect(names.name(for: "93.184.215.14") == "example.com")
}

@Test func nothingButFailureWhileTorIsntReady() async {
    let answer = await DNSAnswerer.answer(query(DNSType.a), torReady: false, names: NameCache()) { _ in
        Issue.record("must not resolve")
        return []
    }
    #expect(rcode(answer) == 2)
}

@Test func otherTypesGetAnEmptyAnswer() async {
    let answer = await DNSAnswerer.answer(query(16), torReady: true, names: NameCache()) { _ in
        Issue.record("must not resolve")
        return []
    }
    #expect(rcode(answer) == 0)
    #expect(answers(answer) == 0)
}

@Test func aFailedLookupIsAServerFailure() async {
    let answer = await DNSAnswerer.answer(query(DNSType.aaaa), torReady: true, names: NameCache()) { _ in
        throw EngineError("no exit")
    }
    #expect(rcode(answer) == 2)
}

@Test func garbageGetsNoAnswer() async {
    #expect(await DNSAnswerer.answer(Data([1, 2, 3]), torReady: true, names: NameCache()) { _ in [] } == nil)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | sort -u | head -2`
Expected: `cannot find 'DNSAnswerer' in scope`.

- [ ] **Step 3: Implement**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/DNSAnswerer.swift`:

```swift
import Foundation

/// One DNS query in, one answer out. Every query gets an answer (spike Q6):
/// through Tor, empty, or SERVFAIL. nil only for bytes that aren't a query.
public enum DNSAnswerer {
    public static func answer(_ query: Data, torReady: Bool, names: NameCache, now: Date = .now,
                              resolve: (String) async throws -> [String]) async -> Data? {
        guard let q = DNSMessage.parseQuery(query) else { return nil }
        guard torReady else { return DNSMessage.serverFailure(q) }
        guard DNSType.resolvable(q.question.type) else { return DNSMessage.empty(q) }
        do {
            let addresses = try await resolve(q.question.name)
            for address in addresses { names.record(ip: address, name: q.question.name, now: now) }
            return DNSMessage.answer(q, addresses: addresses)
        } catch {
            return DNSMessage.serverFailure(q)
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): answer every DNS query through Tor, empty or SERVFAIL" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: ProxyEngine and settings, the app's side

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/Settings.swift`
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift`
- Create: `macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/ProxyEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

`macos/Packages/TortugaProxyKit/Tests/TortugaProxyKitTests/ProxyEngineTests.swift`:

```swift
import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

final class FakeLink: ExtensionLink, @unchecked Sendable {
    let states: AsyncStream<ExtensionState>
    private let feed: AsyncStream<ExtensionState>.Continuation
    private let lock = NSLock()
    private var sent: [ExtensionCommand] = []
    private(set) var closed = false
    var reply: ExtensionReply = .ok

    init() { (states, feed) = AsyncStream.makeStream(of: ExtensionState.self) }

    var commands: [ExtensionCommand] { lock.withLock { sent } }
    func send(_ command: ExtensionCommand) async throws -> ExtensionReply {
        lock.withLock { sent.append(command) }
        return reply
    }
    func close() {
        lock.withLock { closed = true }
        feed.finish()
    }
    func push(_ state: ExtensionState) { feed.yield(state) }
}

final class FakeControl: ProxyControl, @unchecked Sendable {
    let link = FakeLink()
    private let lock = NSLock()
    private var calls: [Bool] = []
    var asksForApproval = false
    var activationError: (any Error)?

    var enabled: [Bool] { lock.withLock { calls } }
    var helperPaths: (helper: String, pt: String) { ("/A/helper", "/A/pt") }

    func activate(onNeedsApproval: @escaping @Sendable () -> Void) async throws {
        if asksForApproval { onNeedsApproval() }
        if let activationError { throw activationError }
    }
    func setEnabled(_ on: Bool, configuration: ProxyConfiguration) async throws {
        lock.withLock { calls.append(on) }
    }
    func connect() async throws -> any ExtensionLink { link }
}

final class MemoryStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredSettings
    init(_ settings: StoredSettings = StoredSettings()) { stored = settings }
    func load() -> StoredSettings { lock.withLock { stored } }
    func save(_ settings: StoredSettings) { lock.withLock { stored = settings } }
}

private func statuses(of engine: ProxyEngine) async -> AsyncStream<EngineState> { await engine.states() }

@Suite struct ProxyEngineTests {
    @Test func torActivatesEnablesConnectsAndConfigures() async throws {
        let control = FakeControl()
        let engine = ProxyEngine(control: control, store: MemoryStore())
        try await engine.setMode(.tor)
        #expect(control.enabled == [true])
        guard case .configure(let config) = control.link.commands.first else {
            Issue.record("no configure")
            return
        }
        #expect(config.helperPath == "/A/helper")
        #expect(config.bridge == .snowflake)
        control.link.push(ExtensionState(status: .on, trunk: Trunk(bridge: .snowflake, guardRelay: nil), apps: []))
        try await eventually { await engine.current.status == .on }
        #expect(await engine.current.mode == .tor)
        #expect(await engine.current.downloadsAvailable == false)
    }

    @Test func waitingForApprovalSaysWhatToDo() async throws {
        let control = FakeControl()
        control.asksForApproval = true
        control.activationError = EngineError("The user didn't allow it")
        let engine = ProxyEngine(control: control, store: MemoryStore())
        var seen = await engine.states().makeAsyncIterator()
        await #expect(throws: EngineError("The user didn't allow it")) { try await engine.setMode(.tor) }
        var reasons: [Status] = []
        for _ in 0..<4 { if let s = await seen.next() { reasons.append(s.status) } }
        #expect(reasons.contains(.failed(reason: Status.allowExtensionReason)))
        #expect(control.enabled.isEmpty)
    }

    @Test func directTurnsEverythingOff() async throws {
        let control = FakeControl()
        let engine = ProxyEngine(control: control, store: MemoryStore())
        try await engine.setMode(.tor)
        try await engine.setMode(.direct)
        #expect(control.enabled == [true, false])
        #expect(control.link.closed)
        #expect(await engine.current.status == .off)
    }

    @Test func settingsAreSavedAndReachTheExtension() async throws {
        let control = FakeControl()
        let store = MemoryStore()
        let engine = ProxyEngine(control: control, store: store)
        try await engine.setMode(.tor)
        try await engine.addException(AppID("com.apple.mail"))
        try await engine.selectBridge(nil)
        #expect(store.load().exceptions == [AppID("com.apple.mail")])
        #expect(store.load().bridge == nil)
        guard case .configure(let config) = control.link.commands.last else {
            Issue.record("no configure")
            return
        }
        #expect(config.exceptions == ["com.apple.mail"])
        #expect(config.bridge == nil)
        #expect(await engine.current.exceptions == [AppID("com.apple.mail")])
    }

    @Test func badBridgeLinesAreRefused() async {
        let engine = ProxyEngine(control: FakeControl(), store: MemoryStore())
        await #expect(throws: EngineError("Line 1: no 40-character fingerprint after the address")) {
            try await engine.saveBridgeLines(["obfs4 192.0.2.1:443 nope"], for: .obfs4)
        }
    }

    @Test func aGoneExtensionIsReported() async throws {
        let control = FakeControl()
        let engine = ProxyEngine(control: control, store: MemoryStore())
        try await engine.setMode(.tor)
        control.link.close()
        try await eventually { await engine.current.status == .failed(reason: "Tortuga's network extension isn't running") }
    }

    @Test func commandsGoThroughTheLinkAndFailuresComeBack() async throws {
        let control = FakeControl()
        let engine = ProxyEngine(control: control, store: MemoryStore())
        await #expect(throws: EngineError("Tor isn't on")) { try await engine.newCircuit(for: nil) }
        await #expect(throws: EngineError("Switch to Tor to get bridge lines from bridges.torproject.org")) {
            try await engine.fetchBridgeLines(.obfs4)
        }
        try await engine.setMode(.tor)
        try await engine.newCircuit(for: AppID("a"))
        #expect(control.link.commands.last == .newCircuit(app: "a"))
        control.link.reply = .failure("Tor isn't on")
        await #expect(throws: EngineError("Tor isn't on")) { try await engine.restart() }
        control.link.reply = .lines(["Bridge obfs4 x"])
        #expect(try await engine.fetchBridgeLines(.obfs4) == ["Bridge obfs4 x"])
    }

    @Test func downloadsComeLater() async {
        let engine = ProxyEngine(control: FakeControl(), store: MemoryStore())
        await #expect(throws: EngineError("Downloads come in a later version")) {
            try await engine.addDownload(.magnet("magnet:?xt=urn:btih:a"))
        }
    }

    @Test func torComesBackAtLaunchIfItWasOn() async {
        let control = FakeControl()
        var saved = StoredSettings()
        saved.mode = .tor
        let engine = ProxyEngine(control: control, store: MemoryStore(saved))
        await engine.resume()
        #expect(control.enabled == [true])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "error:" | sort -u | head -3`
Expected: `cannot find type 'ExtensionLink' in scope`.

- [ ] **Step 3: Implement the settings**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/Settings.swift`:

```swift
import Foundation
import TortugaKit

/// The user's choices, kept by the app.
public struct StoredSettings: Codable, Sendable, Equatable {
    public var mode: Mode = .direct
    public var bridge: BridgeKind? = .snowflake
    public var lines: [BridgeKind: [String]] = [:]
    public var exceptions: [AppID] = []

    public init() {}
}

public protocol SettingsStore: Sendable {
    func load() -> StoredSettings
    func save(_ settings: StoredSettings)
}

/// StoredSettings as JSON in UserDefaults.
public struct DefaultsSettingsStore: SettingsStore {
    public static let key = "proxySettings"

    public init() {}

    public func load() -> StoredSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(StoredSettings.self, from: data) else { return StoredSettings() }
        return settings
    }

    public func save(_ settings: StoredSettings) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
```

- [ ] **Step 4: Implement ProxyEngine**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/ProxyEngine.swift`:

```swift
import Foundation
import TortugaKit

/// The system side the app drives: the system extension, its two network
/// configurations, and the XPC connection to it. Real in the app, a fake in tests.
public protocol ProxyControl: Sendable {
    /// Install or update the extension. Calls `onNeedsApproval` when macOS
    /// waits for the user, and returns once it's active.
    func activate(onNeedsApproval: @escaping @Sendable () -> Void) async throws
    /// Turn both proxies on (with `configuration`) or off.
    func setEnabled(_ on: Bool, configuration: ProxyConfiguration) async throws
    func connect() async throws -> any ExtensionLink
    /// tortuga-helper and pt/ in this app's bundle.
    var helperPaths: (helper: String, pt: String) { get }
}

/// A connection to the running extension.
public protocol ExtensionLink: AnyObject, Sendable {
    func send(_ command: ExtensionCommand) async throws -> ExtensionReply
    /// The extension's state; finishes when the connection is gone.
    var states: AsyncStream<ExtensionState> { get }
    func close()
}

/// The real engine, on the app's side: the user's settings here, Tor's state
/// from the extension.
public actor ProxyEngine: TortugaEngine {
    public static let downloadsLater = "Downloads come in a later version"
    static let extensionGone = "Tortuga's network extension isn't running"

    private let control: any ProxyControl
    private let store: any SettingsStore
    private var settings: StoredSettings
    private var remote = ExtensionState.idle
    private var local: Status = .off
    private var link: (any ExtensionLink)?
    private var linkTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<EngineState>.Continuation] = [:]

    public init(control: any ProxyControl, store: any SettingsStore) {
        self.control = control
        self.store = store
        self.settings = store.load()
    }

    public var current: EngineState {
        var state = EngineState()
        state.mode = settings.mode
        state.bridges = BridgeSettings(selected: settings.bridge, lines: settings.lines)
        state.exceptions = settings.exceptions
        state.downloadsAvailable = false
        if link != nil {
            state.status = remote.status
            state.trunk = remote.trunk
            state.apps = remote.apps
        } else {
            state.status = local
        }
        return state
    }

    /// Bring Tor back at launch if it was on.
    public func resume() async {
        if settings.mode == .tor { try? await turnOn() }
    }

    // MARK: TortugaEngine

    public func states() -> AsyncStream<EngineState> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineState.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        continuation.yield(current)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.forget(id) } }
        return stream
    }

    public func setMode(_ mode: Mode) async throws {
        settings.mode = mode
        store.save(settings)
        if mode == .tor { try await turnOn() } else { await turnOff() }
    }

    public func restart() async throws {
        guard settings.mode == .tor else { throw EngineError("Switch to Tor first") }
        if let link { try check(await link.send(.restart)) } else { try await turnOn() }
    }

    public func newCircuit(for app: AppID?) async throws {
        guard let link else { throw EngineError("Tor isn't on") }
        try check(await link.send(.newCircuit(app: app?.id)))
    }

    public func selectBridge(_ kind: BridgeKind?) async throws {
        settings.bridge = kind
        try await settingsChanged()
    }

    public func saveBridgeLines(_ lines: [String], for kind: BridgeKind) async throws {
        guard kind.needsLines else { throw EngineError("Snowflake needs no lines") }
        let parsed = BridgeLines.parse(lines.joined(separator: "\n"), for: kind)
        if let first = parsed.errors.first { throw EngineError(first) }
        settings.lines[kind] = parsed.lines
        try await settingsChanged()
    }

    public func fetchBridgeLines(_ kind: BridgeKind) async throws -> [String] {
        guard let link else { throw EngineError("Switch to Tor to get bridge lines from bridges.torproject.org") }
        switch try await link.send(.fetchBridgeLines(kind)) {
        case .lines(let lines): return lines
        case .failure(let message): throw EngineError(message)
        case .ok: return []
        }
    }

    public func addException(_ app: AppID) async throws {
        if !settings.exceptions.contains(app) { settings.exceptions.append(app) }
        try await settingsChanged()
    }

    public func removeException(_ app: AppID) async throws {
        settings.exceptions.removeAll { $0 == app }
        try await settingsChanged()
    }

    public func addDownload(_ source: DownloadSource) async throws { throw EngineError(Self.downloadsLater) }
    public func pauseDownload(_ id: Download.ID) async throws { throw EngineError(Self.downloadsLater) }
    public func resumeDownload(_ id: Download.ID) async throws { throw EngineError(Self.downloadsLater) }
    public func removeDownload(_ id: Download.ID) async throws { throw EngineError(Self.downloadsLater) }

    // MARK: On and off

    private func turnOn() async throws {
        local = .starting(step: "Starting Tortuga's network extension", progress: 0)
        publish()
        do {
            try await control.activate(onNeedsApproval: { [weak self] in
                Task { await self?.waitingForApproval() }
            })
            try await control.setEnabled(true, configuration: configuration())
            if link == nil { try await attach() } else { try check(await link!.send(.configure(configuration()))) }
        } catch {
            local = .failed(reason: error.localizedDescription)
            publish()
            throw error
        }
    }

    private func turnOff() async {
        linkTask?.cancel()
        linkTask = nil
        link?.close()
        link = nil
        remote = .idle
        try? await control.setEnabled(false, configuration: configuration())
        local = .off
        publish()
    }

    private func attach() async throws {
        let link = try await control.connect()
        self.link = link
        try check(await link.send(.configure(configuration())))
        let states = link.states
        linkTask = Task { [weak self] in
            for await state in states { await self?.received(state) }
            await self?.lost(link)
        }
    }

    private func waitingForApproval() {
        guard link == nil else { return }
        local = .failed(reason: Status.allowExtensionReason)
        publish()
    }

    private func received(_ state: ExtensionState) {
        remote = state
        publish()
    }

    private func lost(_ gone: any ExtensionLink) {
        guard let link, link === gone else { return }
        self.link = nil
        remote = .idle
        local = settings.mode == .tor ? .failed(reason: Self.extensionGone) : .off
        publish()
    }

    // MARK: Helpers

    private func configuration() -> ProxyConfiguration {
        ProxyConfiguration(bridge: settings.bridge, lines: settings.lines, exceptions: settings.exceptions.map(\.id),
                           helperPath: control.helperPaths.helper, ptDir: control.helperPaths.pt)
    }

    private func settingsChanged() async throws {
        store.save(settings)
        publish()
        if let link { try check(await link.send(.configure(configuration()))) }
    }

    private func check(_ reply: ExtensionReply) throws {
        if case .failure(let message) = reply { throw EngineError(message) }
    }

    private func publish() {
        let state = current
        for continuation in observers.values { continuation.yield(state) }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|recorded an issue|Test run with"`
Expected: every test passes, no warnings.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): ProxyEngine, the app's real engine, with settings kept in the app" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: XPC between app and extension

**Files:**
- Create: `macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/XPC.swift`

There are no unit tests for this task. XPC to a system extension can't be
exercised in `swift test`; the live check covers it.

- [ ] **Step 1: Write the XPC protocols and the app's side**

`macos/Packages/TortugaProxyKit/Sources/TortugaProxyKit/XPC.swift`:

```swift
import Foundation

/// What the extension exports.
@objc public protocol ProxyXPC {
    /// One `ExtensionCommand` (JSON) → one `ExtensionReply` (JSON).
    func perform(_ command: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Start sending `ExtensionState`s to the app's exported `AppXPC`.
    func subscribe()
}

/// What the app exports, for the extension to push state to.
@objc public protocol AppXPC {
    func stateChanged(_ state: Data)
}

/// The app's connection to the extension's Mach service (in the system
/// domain, so `.privileged`).
public final class XPCLink: NSObject, ExtensionLink, @unchecked Sendable {
    public let states: AsyncStream<ExtensionState>
    private let feed: AsyncStream<ExtensionState>.Continuation
    private let connection: NSXPCConnection

    public init(machServiceName: String) {
        let (stream, feed) = AsyncStream.makeStream(of: ExtensionState.self, bufferingPolicy: .bufferingNewest(8))
        states = stream
        self.feed = feed
        connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyXPC.self)
        connection.exportedInterface = NSXPCInterface(with: AppXPC.self)
        connection.exportedObject = Receiver(feed: feed)
        connection.invalidationHandler = { feed.finish() }
        connection.interruptionHandler = { feed.finish() }
        connection.resume()
        (connection.remoteObjectProxyWithErrorHandler { _ in feed.finish() } as? ProxyXPC)?.subscribe()
    }

    public func send(_ command: ExtensionCommand) async throws -> ExtensionReply {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExtensionReply, Error>) in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ continuation.resume(throwing: $0) }) as? ProxyXPC else {
                continuation.resume(throwing: EngineError(ProxyEngine.extensionGone))
                return
            }
            proxy.perform(Wire.encode(command)) { data in
                continuation.resume(returning: Wire.decode(ExtensionReply.self, data) ?? .failure("The extension gave an answer Tortuga can't read"))
            }
        }
    }

    public func close() {
        connection.invalidate()
        feed.finish()
    }

    private final class Receiver: NSObject, AppXPC, @unchecked Sendable {
        let feed: AsyncStream<ExtensionState>.Continuation
        init(feed: AsyncStream<ExtensionState>.Continuation) { self.feed = feed }
        func stateChanged(_ state: Data) {
            if let decoded = Wire.decode(ExtensionState.self, state) { feed.yield(decoded) }
        }
    }
}
```

- [ ] **Step 2: Build and run the tests**

Run: `swift test --package-path macos/Packages/TortugaProxyKit 2>&1 | grep -E "warning:|error:|Test run with"`
Expected: it builds without warnings, and every test passes.

- [ ] **Step 3: Commit**

```bash
git add macos/Packages/TortugaProxyKit
git commit -m "feat(macos): XPC protocols and the app's link to the extension" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The real extension

**Files:**
- Delete: `macos/TortugaProxy/SpikeTransparentProxy.swift`, `macos/TortugaProxy/SpikeDNSProxy.swift`, `macos/TortugaProxy/SpikeHelperCheck.swift`
- Create: `macos/TortugaProxy/Shared.swift`, `macos/TortugaProxy/TransparentProxy.swift`, `macos/TortugaProxy/TCPRelay.swift`, `macos/TortugaProxy/DNSProxy.swift`, `macos/TortugaProxy/XPCServer.swift`
- Modify: `macos/TortugaProxy/main.swift`, `macos/project.yml`

- [ ] **Step 1: Remove the spike's providers**

Run: `git rm -q macos/TortugaProxy/SpikeTransparentProxy.swift macos/TortugaProxy/SpikeDNSProxy.swift macos/TortugaProxy/SpikeHelperCheck.swift`

- [ ] **Step 2: Write the shared core**

`macos/TortugaProxy/Shared.swift`:

```swift
import Foundation
import os
import TortugaKit
import TortugaProxyKit

let proxyLog = Logger(subsystem: "org.tortuga.app", category: "proxy")

/// The extension process's one core, shared by both providers and XPC.
enum Shared {
    static let core = ProxyCore(launcher: ProcessLauncher(dataDirectory: dataDirectory))
    static let names = NameCache()

    /// The helper's Arti state, in the extension's container.
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "tortuga-helper")
    }

    static func handle(_ command: ExtensionCommand) async -> ExtensionReply {
        do {
            switch command {
            case .configure(let configuration):
                await core.configure(configuration)
            case .restart:
                await core.restart()
            case .newCircuit(let app):
                try await core.newCircuit(app: app)
            case .fetchBridgeLines(let kind):
                return .lines(try await core.fetchBridgeLines(kind))
            }
            return .ok
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// For values NetworkExtension hands us that Swift can't see are safe to
/// pass to a task (flows are thread-safe objects).
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
```

- [ ] **Step 3: Write the transparent proxy**

`macos/TortugaProxy/TransparentProxy.swift`:

```swift
import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// Every TCP and UDP flow off this Mac, except local networks (excluded in
/// the settings): to Tor by the app's own circuit, straight out for
/// exceptions and our own programs, or closed.
final class TransparentProxy: NETransparentProxyProvider {
    /// Loopback, private, link-local, multicast: never offered to us.
    static let localNetworks: [(String, Int)] = [
        ("127.0.0.0", 8), ("10.0.0.0", 8), ("172.16.0.0", 12), ("192.168.0.0", 16), ("169.254.0.0", 16),
        ("224.0.0.0", 4), ("255.255.255.255", 32), ("::1", 128), ("fe80::", 10), ("fc00::", 7), ("ff00::", 8),
    ]

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]
        settings.excludedNetworkRules = Self.localNetworks.map { address, prefix in
            NENetworkRule(remoteNetworkEndpoint: nw_endpoint_create_host(address, "0"), remotePrefix: prefix,
                          localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound)
        }
        let configuration = ProxyConfiguration(providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration)
        setTunnelNetworkSettings(settings) { error in
            if let error { proxyLog.error("proxy settings failed: \(error.localizedDescription, privacy: .public)") }
            Task {
                if let configuration { await Shared.core.configure(configuration) }
                await Shared.core.start()
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task {
            await Shared.core.stop()
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let snapshot = Shared.core.routes.snapshot()
        var ip = ""
        var port = 0
        if let tcp = flow as? NEAppProxyTCPFlow, case .hostPort(let host, let p) = tcp.remoteFlowEndpoint {
            ip = Self.address(host)
            port = Int(p.rawValue)
        }
        let info = FlowInfo(app: flow.metaData.sourceAppSigningIdentifier, remoteHost: flow.remoteHostname,
                            remoteIP: ip, port: port, isUDP: flow is NEAppProxyUDPFlow)
        switch FlowRouter.decide(info, snapshot.state, names: Shared.names) {
        case .direct:
            return false
        case .refuse:
            Self.refuse(flow)
            return true
        case .tor(let host, let port, let isolation):
            guard let socksPort = snapshot.socksPort, let tcp = flow as? NEAppProxyTCPFlow else {
                Self.refuse(flow)
                return true
            }
            TCPRelay(flow: tcp, host: host, port: port, isolation: isolation, socksPort: socksPort).start()
            return true
        }
    }

    static func refuse(_ flow: NEAppProxyFlow) {
        let error = NEAppProxyFlowError(.refused)
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }

    static func address(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }
}
```

- [ ] **Step 4: Write the relay**

`macos/TortugaProxy/TCPRelay.swift`:

```swift
import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// One app's TCP flow through the helper's SOCKS port: handshake with the
/// app's ID as username, CONNECT, then bytes both ways until both sides close.
final class TCPRelay: @unchecked Sendable {
    private let flow: NEAppProxyTCPFlow
    private let host: String
    private let port: Int
    private let isolation: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.tortuga.relay")
    private let lock = NSLock()
    private var finished = false
    private var opened = false
    private var closedHalves = 0

    init(flow: NEAppProxyTCPFlow, host: String, port: Int, isolation: String, socksPort: Int) {
        self.flow = flow
        self.host = host
        self.port = port
        self.isolation = isolation
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(socksPort)) ?? 9150, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: handshake()
            case .failed, .cancelled: fail()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func handshake() {
        send(Socks5.greeting) { [self] in
            receive(2) { [self] reply in
                guard (try? Socks5.checkMethod(reply)) != nil else { return fail() }
                send(Socks5.auth(user: isolation, password: "x")) { [self] in
                    receive(2) { [self] reply in
                        guard (try? Socks5.checkAuth(reply)) != nil else { return fail() }
                        send(Socks5.connect(host: host, port: port)) { [self] in
                            receive(5) { [self] head in
                                guard let total = try? Socks5.connectReplyLength(head) else { return fail() }
                                receive(total - 5) { [self] _ in openFlow() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func openFlow() {
        flow.open(withLocalFlowEndpoint: nil) { [self] error in
            guard error == nil else { return fail() }
            lock.withLock { opened = true }
            let app = isolation
            Task { await Shared.core.flowOpened(app: app) }
            flowToSocks()
            socksToFlow()
        }
    }

    private func flowToSocks() {
        flow.readData { [self] data, error in
            guard let data, !data.isEmpty, error == nil else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return halfClosed()
            }
            connection.send(content: data, completion: .contentProcessed { [self] error in
                if error == nil { flowToSocks() } else { fail() }
            })
        }
    }

    private func socksToFlow() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                flow.write(data) { [self] error in
                    if error != nil { return fail() }
                    if isComplete {
                        flow.closeWriteWithError(nil)
                        halfClosed()
                    } else {
                        socksToFlow()
                    }
                }
            } else {
                flow.closeWriteWithError(nil)
                if error != nil { fail() } else { halfClosed() }
            }
        }
    }

    private func send(_ bytes: [UInt8], then next: @escaping @Sendable () -> Void) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] error in
            if error == nil { next() } else { fail() }
        })
    }

    private func receive(_ count: Int, then next: @escaping @Sendable ([UInt8]) -> Void) {
        guard count > 0 else { return next([]) }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, _, error in
            guard let data, data.count == count, error == nil else { return fail() }
            next([UInt8](data))
        }
    }

    private func halfClosed() {
        let both = lock.withLock { closedHalves += 1; return closedHalves >= 2 }
        if both { finish(error: nil) }
    }

    private func fail() {
        finish(error: NEAppProxyFlowError(.hostUnreachable))
    }

    private func finish(error: (any Error)?) {
        let (first, wasOpen) = lock.withLock { () -> (Bool, Bool) in
            defer { finished = true }
            return (!finished, opened)
        }
        guard first else { return }
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        connection.stateUpdateHandler = nil
        connection.cancel()
        if wasOpen {
            let app = isolation
            Task { await Shared.core.flowClosed(app: app) }
        }
    }
}
```

- [ ] **Step 5: Write the DNS proxy**

`macos/TortugaProxy/DNSProxy.swift`:

```swift
import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// Every DNS query on this Mac. Each is answered here, through Tor or with a
/// failure; returning false would drop it (spike Q6).
final class DNSProxy: NEDNSProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let udp = flow as? NEAppProxyUDPFlow else {
            // DNS over TCP: closed; resolvers retry over UDP.
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return true
        }
        let boxed = Unchecked(value: udp)
        udp.open(withLocalFlowEndpoint: nil) { error in
            if error == nil { Self.serve(boxed) }
        }
        return true
    }

    private static func serve(_ boxed: Unchecked<NEAppProxyUDPFlow>) {
        boxed.value.readDatagrams { datagrams, error in
            guard let datagrams, error == nil, !datagrams.isEmpty else {
                boxed.value.closeReadWithError(nil)
                boxed.value.closeWriteWithError(nil)
                return
            }
            for (query, endpoint) in datagrams {
                let sender = Unchecked(value: endpoint)
                Task {
                    let ready = Shared.core.routes.snapshot().state.torReady
                    let answer = await DNSAnswerer.answer(query, torReady: ready, names: Shared.names) { name in
                        try await Shared.core.resolve(name)
                    }
                    if let answer { boxed.value.writeDatagrams([(answer, sender.value)]) { _ in } }
                }
            }
            serve(boxed)
        }
    }
}
```

- [ ] **Step 6: Write the XPC server and the entry point**

`macos/TortugaProxy/XPCServer.swift`:

```swift
import Foundation
import TortugaProxyKit

/// The extension's Mach service: only the Tortuga app of this team may connect.
final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let requirement: String

    init?(bundle: Bundle) {
        guard let extensionInfo = bundle.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let service = extensionInfo["NEMachServiceName"] as? String,
              let team = bundle.object(forInfoDictionaryKey: "TortugaTeamID") as? String else { return nil }
        listener = NSXPCListener(machServiceName: service)
        requirement = #"anchor apple generic and identifier "org.tortuga.app" and certificate leaf[subject.OU] = "\#(team)""#
        super.init()
    }

    func start() {
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ProxyXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: AppXPC.self)
        let session = Session(connection: connection)
        connection.exportedObject = session
        connection.invalidationHandler = { session.end() }
        connection.resume()
        return true
    }
}

/// One app connection: commands in, states out.
private final class Session: NSObject, ProxyXPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private var pusher: Task<Void, Never>?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func perform(_ command: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = Wire.decode(ExtensionCommand.self, command) else {
            reply(Wire.encode(ExtensionReply.failure("The extension can't read that command")))
            return
        }
        Task { reply(Wire.encode(await Shared.handle(decoded))) }
    }

    func subscribe() {
        guard let app = connection?.remoteObjectProxy as? AppXPC else { return }
        let boxed = Unchecked(value: app)
        pusher?.cancel()
        pusher = Task {
            for await state in await Shared.core.states() {
                boxed.value.stateChanged(Wire.encode(state))
            }
        }
    }

    func end() {
        pusher?.cancel()
    }
}
```

Replace `macos/TortugaProxy/main.swift` with:

```swift
import Foundation
import NetworkExtension

let xpc = XPCServer(bundle: .main)
xpc?.start()
if xpc == nil { proxyLog.error("no Mach service name or team in Info.plist: the app can't reach the extension") }

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
```

- [ ] **Step 7: Point the extension at the real providers, and link the package**

In `macos/project.yml`:

1. Under `packages:`, add:

```yaml
  TortugaProxyKit:
    path: Packages/TortugaProxyKit
```

2. Under `TortugaProxy:` → `dependencies:`, add `- package: TortugaProxyKit`.
   Under `Tortuga:` → `dependencies:`, add `- package: TortugaProxyKit`.

3. Under `TortugaProxy:` → `info: properties:`:
   - change the two `NEProviderClasses` values to
     `$(PRODUCT_MODULE_NAME).TransparentProxy` and
     `$(PRODUCT_MODULE_NAME).DNSProxy`;
   - add `TortugaTeamID: $(DEVELOPMENT_TEAM)`;
   - set `CFBundleShortVersionString: "0.2.0"` and `CFBundleVersion: "5"`.

4. Under `Tortuga:` → `info: properties:`, add
   `TortugaProxyMachService: $(DEVELOPMENT_TEAM).org.tortuga.app.proxy`.

- [ ] **Step 8: Build**

Run: `cd macos && xcodegen generate && xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -v "^    export" | grep -E "error:|warning: .*(TortugaProxy|Relay|DNSProxy|XPC)|BUILD" | sort -u | head -20`
Expected: `** BUILD SUCCEEDED **` and no warnings from the extension's files.
Where Swift 6 complains that a NetworkExtension object crosses into a
`Task`, wrap it in `Unchecked` as `DNSProxy` does. Don't turn strict
concurrency off.

- [ ] **Step 9: Commit**

```bash
git add -A macos/TortugaProxy macos/project.yml
git commit -m "feat(macos): the real extension: transparent proxy, DNS proxy, SOCKS relay, XPC" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The app drives the real extension

**Files:**
- Create: `macos/Tortuga/SystemProxyControl.swift`
- Delete: `macos/Tortuga/SpikeWindow.swift`
- Modify: `macos/Tortuga/TortugaApp.swift`
- Modify: `macos/Packages/TortugaUI/Sources/TortugaUI/StatusLine.swift`, `DownloadsView.swift`, `SettingsView.swift`

- [ ] **Step 1: Write the system side**

`macos/Tortuga/SystemProxyControl.swift`:

```swift
import Foundation
import NetworkExtension
import SystemExtensions
import TortugaKit
import TortugaProxyKit

/// The real ProxyControl: the system extension, its two network
/// configurations, and XPC to it.
final class SystemProxyControl: ProxyControl, @unchecked Sendable {
    static let extensionID = "org.tortuga.app.proxy"

    var helperPaths: (helper: String, pt: String) {
        let contents = Bundle.main.bundleURL
            .appending(path: "Contents/Library/SystemExtensions/\(Self.extensionID).systemextension/Contents")
        return (contents.appending(path: "MacOS/tortuga-helper").path, contents.appending(path: "Resources/pt").path)
    }

    func activate(onNeedsApproval: @escaping @Sendable () -> Void) async throws {
        try await Activation(onNeedsApproval: onNeedsApproval).run()
    }

    func setEnabled(_ on: Bool, configuration: ProxyConfiguration) async throws {
        try await Self.apply(on, configuration)
    }

    func connect() async throws -> any ExtensionLink {
        guard let service = Bundle.main.object(forInfoDictionaryKey: "TortugaProxyMachService") as? String else {
            throw EngineError("Tortuga's build has no Mach service name for its extension")
        }
        return XPCLink(machServiceName: service)
    }

    @MainActor
    private static func apply(_ on: Bool, _ configuration: ProxyConfiguration) async throws {
        let manager = try await NETransparentProxyManager.loadAllFromPreferences().first ?? NETransparentProxyManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionID
        proto.serverAddress = "Tortuga"
        proto.providerConfiguration = try configuration.providerConfiguration()
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Tortuga"
        manager.isEnabled = on
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if on {
            if manager.connection.status != .connected { try manager.connection.startVPNTunnel() }
        } else {
            manager.connection.stopVPNTunnel()
        }

        let dns = NEDNSProxyManager.shared()
        try await dns.loadFromPreferences()
        let dnsProto = NEDNSProxyProviderProtocol()
        dnsProto.providerBundleIdentifier = extensionID
        dnsProto.serverAddress = "Tortuga"
        dns.providerProtocol = dnsProto
        dns.localizedDescription = "Tortuga DNS"
        dns.isEnabled = on
        try await dns.saveToPreferences()
    }
}

/// One activation request, as async.
private final class Activation: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let onNeedsApproval: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(onNeedsApproval: @escaping @Sendable () -> Void) {
        self.onNeedsApproval = onNeedsApproval
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: SystemProxyControl.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onNeedsApproval()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        continuation?.resume()
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
```

- [ ] **Step 2: Real engine by default; DemoEngine with -scenario**

Run: `git rm -q macos/Tortuga/SpikeWindow.swift`

In `macos/Tortuga/TortugaApp.swift`:
- add `import TortugaProxyKit` to the imports;
- remove the `#if DEBUG … Window("Spike", …) … #endif` block;
- replace the `@State private var model = …` line and the `static var scenario` property with:

```swift
    @State private var model = AppModel(engine: TortugaApp.makeEngine())

    /// `-scenario <name>` (UI tests) or the Demo tab's choice runs DemoEngine;
    /// otherwise the real engine.
    static func makeEngine() -> any TortugaEngine {
        if let name = UserDefaults.standard.string(forKey: "scenario"), let scenario = Scenario(rawValue: name) {
            return DemoEngine.running(scenario)
        }
        let engine = ProxyEngine(control: SystemProxyControl(), store: DefaultsSettingsStore())
        Task { await engine.resume() }
        return engine
    }
```

- [ ] **Step 3: UI touches**

In `macos/Packages/TortugaUI/Sources/TortugaUI/StatusLine.swift`, inside
`case .blocked, .failed:`, before `Button("Restart")`, add:

```swift
                    if state.status == .failed(reason: Status.allowExtensionReason) {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.route)
                    }
```

Add `import AppKit` at the top of `StatusLine.swift`.

In `DownloadsView.swift`, at the start of the `VStack(spacing: 8)` inside
`DownloadsView.body`, add:

```swift
                if !model.state.downloadsAvailable {
                    Text("Downloads come in a later version.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
```

Change the next `if model.state.downloads.isEmpty {` to
`if model.state.downloadsAvailable, model.state.downloads.isEmpty {`.

In `SettingsView.swift`, change `DemoSettings` so it can go back to the
real engine:

```swift
#if DEBUG
/// Debug builds only: swap the DemoEngine scenario, or go back to the real
/// engine (takes effect when Tortuga next opens).
struct DemoSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("scenario") private var scenario = "real"

    var body: some View {
        Form {
            Picker("Engine", selection: $scenario) {
                Text("Real (Tor)").tag("real")
                ForEach(Scenario.allCases) { Text("Demo: \($0.rawValue)").tag($0.rawValue) }
            }
            .onChange(of: scenario) { _, name in
                if let demo = Scenario(rawValue: name) { model.replace(engine: DemoEngine.running(demo)) }
            }
            if scenario == "real" {
                Text("Quit and reopen Tortuga to use the real engine.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
```

`"real"` isn't a `Scenario`, so `makeEngine()` picks the real engine for it.

- [ ] **Step 4: Build, run the package tests, run the UI tests**

Run:

```bash
for p in TortugaKit TortugaUI TortugaProxyKit; do swift test --package-path macos/Packages/$p 2>&1 | grep -E "warning:|error:|Test run with"; done
cd macos && xcodegen generate && xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -v "^    export" | grep -E "error:|BUILD"
```

Expected: every package test passes, and `** BUILD SUCCEEDED **`.

Then run the UI tests. They use `-scenario`, so they run on `DemoEngine`
unchanged:

`cd macos && TORTUGA_SKIP_HELPER=1 xcodebuild test -project Tortuga.xcodeproj -scheme Tortuga -destination 'platform=macOS' -derivedDataPath build-unsigned 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)"`

Expected: `** TEST SUCCEEDED **`. If the runner can't enable automation mode
(the Mac is locked), say so and leave this to the live check.

- [ ] **Step 5: Commit**

```bash
git add -A macos/Tortuga macos/Packages/TortugaUI
git commit -m "feat(macos): the app runs the real engine, with activation and the extension's settings" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10 (with the user): the live check

**Files:**
- Create: `macos/scripts/live-check.sh`

- [ ] **Step 1: Write the script**

`macos/scripts/live-check.sh`:

```sh
#!/bin/sh
# Checks Tortuga with Tor on: run after switching Tortuga to Tor and waiting
# for "Tor on". Needs sudo for tcpdump and for killing the helper.
set -u
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
FAILED=0

echo "1. Through Tor"
CURL=$(curl -s --max-time 30 https://check.torproject.org/api/ip)
echo "$CURL" | grep -q '"IsTor":true' && ok "curl: $CURL" || bad "curl: $CURL"

echo "2. Two apps, two exits"
PY=$(/usr/bin/python3 -I -c 'import json,urllib.request;print(json.load(urllib.request.urlopen("https://check.torproject.org/api/ip",timeout=30))["IP"])' 2>&1)
C=$(echo "$CURL" | sed -E 's/.*"IP":"([^"]+)".*/\1/')
[ -n "$PY" ] && [ "$PY" != "$C" ] && ok "curl $C, python $PY" || bad "curl $C, python $PY (same exit, or python failed)"

echo "3. DNS through Tor, none on the wire"
sudo tcpdump -i en0 -n -c 5 'port 53' > /tmp/tortuga-dns.txt 2>/dev/null &
TCPDUMP=$!
sleep 1
A=$(dig +short +time=10 example.com | head -1)
sleep 2
sudo kill $TCPDUMP 2>/dev/null
[ -n "$A" ] && ok "dig example.com → $A" || bad "dig example.com: no answer"
[ ! -s /tmp/tortuga-dns.txt ] && ok "no DNS packets on en0" || bad "DNS on en0: $(head -2 /tmp/tortuga-dns.txt)"

echo "4. Nothing goes out while Tor is down"
sudo pkill -x tortuga-helper
sleep 1
curl -s --max-time 8 -o /dev/null https://example.com && bad "curl got through with the helper dead" || ok "curl fails with the helper dead"
echo "   waiting for Tortuga to restart Tor…"
for i in $(seq 1 60); do
  curl -s --max-time 8 https://check.torproject.org/api/ip | grep -q '"IsTor":true' && break
  sleep 2
done
curl -s --max-time 20 https://check.torproject.org/api/ip | grep -q '"IsTor":true' && ok "back through Tor" || bad "Tor didn't come back"

exit $FAILED
```

Run: `chmod +x macos/scripts/live-check.sh`

- [ ] **Step 2: Install, switch on, approve**

Run: `macos/scripts/install-dev.sh -didShowWelcome YES -openWindowAtLaunch YES`

Ask the user to click **Tor** in the window. If the status says "Allow
Tortuga's network extension…", ask them to approve it. Wait until the status
says "Tor on via Snowflake". The first bootstrap through Snowflake can take a
minute or two.

- [ ] **Step 3: Run the check**

Ask the user to run `sudo -v` in the terminal (for the script's
tcpdump and pkill), then run:

`macos/scripts/live-check.sh`

Expected: every line `ok`. While it runs, the Route screen should show curl
and python3 with different exits.

- [ ] **Step 4: Check an exception by hand**

Ask the user to:
1. add Terminal as an exception (Exceptions → Add App… → Terminal);
2. run `curl -s https://check.torproject.org/api/ip` in Terminal, and check
   it shows `"IsTor":false` with their real IP;
3. remove the exception, and check the next `curl` shows `"IsTor":true`.

- [ ] **Step 5: Switch off**

Ask the user to click **Direct**. Then
`curl -s https://check.torproject.org/api/ip` shows `"IsTor":false`.

- [ ] **Step 6: Record and commit**

Append to `docs/spike-findings.md` a section `## Live check (YYYY-MM-DD)`
with the script's output and the exception check's result. Then:

```bash
git add macos/scripts/live-check.sh docs/spike-findings.md
git commit -m "test(macos): live check of the whole-Mac Tor proxy" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

If a check fails, stop and bring the output to the user.

---

### Task 11: Docs

**Files:**
- Modify: `macos/README.md`

- [ ] **Step 1:** In `macos/README.md`, replace the "Real Tor (in
  progress)" section with:

````markdown
## Real Tor

With Tor on, every app on the Mac goes through Tor, each on its own circuit;
DNS goes through Tor; nothing leaves directly while Tor isn't ready.
Excepted apps, local networks, and Tortuga's own helper go out directly.

It needs your team's signing (`Local.xcconfig`, from `Local.xcconfig.example`)
and the app in /Applications:

```sh
scripts/install-dev.sh            # build, install to /Applications, open
```

The first time Tor is switched on, macOS asks you to allow Tortuga's network
extension (System Settings → General → Login Items & Extensions → Network
Extensions). `scripts/live-check.sh` checks it from the terminal with Tor on.

Builds launched with `-scenario <name>`, and the Demo tab in debug builds,
use `DemoEngine` instead.
````

- [ ] **Step 2: Commit**

```bash
git add macos/README.md
git commit -m "docs(macos): the real engine" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Done when

- **Tests:** all package tests pass (TortugaKit, TortugaUI, TortugaProxyKit),
  with no warnings.
- **Builds:** the app builds signed, and the UI tests pass on `DemoEngine`.
- **The live check passes on the user's Mac:**
  - through Tor;
  - two apps, two exits;
  - DNS answered, none on en0;
  - blocked while the helper is dead, then back;
  - an exception goes direct;
  - Direct turns it all off.
