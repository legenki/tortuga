import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

final class FakeLink: ExtensionLink, @unchecked Sendable {
    let states: AsyncStream<ExtensionState>
    private let feed: AsyncStream<ExtensionState>.Continuation
    private let lock = NSLock()
    private var sent: [ExtensionCommand] = []
    private var isClosed = false
    private var nextReply: ExtensionReply = .ok

    init() { (states, feed) = AsyncStream.makeStream(of: ExtensionState.self) }

    var commands: [ExtensionCommand] { lock.withLock { sent } }
    var closed: Bool { lock.withLock { isClosed } }
    var reply: ExtensionReply {
        get { lock.withLock { nextReply } }
        set { lock.withLock { nextReply = newValue } }
    }

    func send(_ command: ExtensionCommand) async throws -> ExtensionReply {
        lock.withLock {
            sent.append(command)
            return nextReply
        }
    }

    func close() {
        lock.withLock { isClosed = true }
        feed.finish()
    }

    func push(_ state: ExtensionState) { feed.yield(state) }
}

final class FakeControl: ProxyControl, @unchecked Sendable {
    private let lock = NSLock()
    private var current = FakeLink()
    private var calls: [Bool] = []
    private var replaces: [Bool] = []
    private var waiting: ExtensionUpdate?
    var asksForApproval = false
    var activationError: (any Error)?

    /// The running extension's link; replacing the extension starts a new one.
    var link: FakeLink { lock.withLock { current } }
    var enabled: [Bool] { lock.withLock { calls } }
    /// `replace` of each activation.
    var activations: [Bool] { lock.withLock { replaces } }
    /// A newer extension in the app than the one running.
    var waitingUpdate: ExtensionUpdate? {
        get { lock.withLock { waiting } }
        set { lock.withLock { waiting = newValue } }
    }
    var helperPaths: (helper: String, pt: String) { ("/A/helper", "/A/pt") }

    func activate(replace: Bool, onNeedsApproval: @escaping @Sendable () -> Void) async throws -> ActivationOutcome {
        if asksForApproval { onNeedsApproval() }
        if let activationError { throw activationError }
        return lock.withLock {
            replaces.append(replace)
            guard let update = waiting else { return .active }
            if replace {
                // The old extension ends, and its connection with it.
                waiting = nil
                current.close()
                current = FakeLink()
                return .active
            }
            return .updateWaiting(update)
        }
    }

    func setEnabled(_ on: Bool, configuration: ProxyConfiguration) async throws {
        lock.withLock { calls.append(on) }
    }

    /// How many connects fail before one works (the Mach service lagging).
    var failingConnects = 0

    func connect() async throws -> any ExtensionLink {
        let fail = lock.withLock {
            guard failingConnects > 0 else { return false }
            failingConnects -= 1
            return true
        }
        if fail { throw NSError(domain: NSCocoaErrorDomain, code: 4097) }
        return link
    }
}

final class MemoryStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredSettings
    init(_ settings: StoredSettings = StoredSettings()) { stored = settings }
    func load() -> StoredSettings { lock.withLock { stored } }
    func save(_ settings: StoredSettings) { lock.withLock { stored = settings } }
}

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

    @Test func aListedAppsHelpersAreNotGoingDirect() async throws {
        let control = FakeControl()
        let store = MemoryStore()
        var saved = StoredSettings()
        saved.torApps = [AppID("com.google.Chrome")]
        store.save(saved)
        let engine = ProxyEngine(control: control, store: store)
        try await engine.setMode(.tor)
        control.link.push(ExtensionState(status: .on, trunk: Trunk(), apps: [],
                                         seenDirect: ["com.google.Chrome.helper", "com.apple.mail"]))
        try await eventually { await engine.current.seenDirect == [AppID("com.apple.mail")] }
    }

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
        #expect(config.torApps == ["com.apple.Safari"])
        #expect(await engine.current.torApps == [AppID("com.apple.Safari")])
        try await engine.removeTorApp(AppID("com.apple.Safari"))
        #expect(store.load().torApps == [])
    }

    @Test func oldSettingsStillDecode() throws {
        let old = #"{"mode":"tor","bridge":null,"lines":[],"exceptions":[{"id":"com.apple.mail"}]}"#
        let settings = try JSONDecoder().decode(StoredSettings.self, from: Data(old.utf8))
        #expect(settings.mode == .tor)
        #expect(settings.bridge == nil)
        #expect(settings.torApps == nil)
        #expect(settings.legacyExceptions == [AppID("com.apple.mail")])
        let written = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!written.contains("exceptions"))
    }

    @Test func oldSettingsWithoutABridgeStillDecode() throws {
        let old = #"{"mode":"tor","lines":[],"exceptions":[]}"#
        let settings = try JSONDecoder().decode(StoredSettings.self, from: Data(old.utf8))
        #expect(settings.bridge == nil)
        #expect(settings.torApps == nil)
    }

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

    @Test func connectingIsRetriedWhileTheExtensionComesUp() async throws {
        let control = FakeControl()
        control.failingConnects = 3
        let engine = ProxyEngine(control: control, store: MemoryStore(), retryDelay: .zero)
        try await engine.setMode(.tor)
        guard case .configure = control.link.commands.first else {
            Issue.record("no configure after the retries")
            return
        }
        control.link.push(ExtensionState(status: .on, trunk: Trunk(), apps: []))
        try await eventually { await engine.current.status == .on }
    }

    @Test func connectingGivesUpAfterTenTries() async throws {
        let control = FakeControl()
        control.failingConnects = 100
        let engine = ProxyEngine(control: control, store: MemoryStore(), retryDelay: .zero)
        await #expect(throws: (any Error).self) { try await engine.setMode(.tor) }
        #expect(control.failingConnects == 100 - ProxyEngine.attachAttempts)
        if case .failed = await engine.current.status {} else { Issue.record("not failed") }
    }

    @Test func aDroppedLinkIsReconnected() async throws {
        let control = FakeControl()
        let engine = ProxyEngine(control: control, store: MemoryStore(), retryDelay: .zero)
        try await engine.setMode(.tor)
        let before = control.link.commands.count
        control.link.close()
        // The fake hands back the same (closed) link, so each reconnect drops
        // at once; the engine tries again, then gives up instead of spinning.
        try await eventually { await engine.current.status == .failed(reason: "Tortuga's network extension isn't running") }
        #expect(control.link.commands.count > before)
    }

    @Test func badBridgeLinesAreRefused() async {
        let engine = ProxyEngine(control: FakeControl(), store: MemoryStore())
        await #expect(throws: EngineError("Line 1: no 40-character fingerprint after the address")) {
            try await engine.saveBridgeLines(["obfs4 192.0.2.1:443 nope"], for: .obfs4)
        }
    }

    @Test func aGoneExtensionIsReported() async throws {
        let control = FakeControl()
        let engine = ProxyEngine(control: control, store: MemoryStore(), retryDelay: .zero)
        try await engine.setMode(.tor)
        control.failingConnects = 100
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

    @Test func torComesBackAtLaunchIfItWasOn() async {
        let control = FakeControl()
        var saved = StoredSettings()
        saved.mode = .tor
        let engine = ProxyEngine(control: control, store: MemoryStore(saved))
        await engine.resume()
        #expect(control.enabled == [true])
    }

    @Test func anUpdateAtLaunchWaitsAndTheRunningExtensionKeepsGoing() async throws {
        let control = FakeControl()
        let update = ExtensionUpdate(from: "0.2.1", to: "0.2.2")
        control.waitingUpdate = update
        var saved = StoredSettings()
        saved.mode = .tor
        let engine = ProxyEngine(control: control, store: MemoryStore(saved))
        await engine.resume()
        #expect(control.activations == [false])
        #expect(control.enabled == [true])
        #expect(await engine.current.pendingUpdate == update)
        guard case .configure = control.link.commands.first else {
            Issue.record("the running extension wasn't configured")
            return
        }
    }

    @Test func switchingToTorReplacesTheExtensionAtOnce() async throws {
        let control = FakeControl()
        control.waitingUpdate = ExtensionUpdate(from: "0.2.1", to: "0.2.2")
        let engine = ProxyEngine(control: control, store: MemoryStore())
        try await engine.setMode(.tor)
        #expect(control.activations == [true])
        #expect(await engine.current.pendingUpdate == nil)
    }

    @Test func finishingAnUpdateReplacesTheExtensionAndReconnects() async throws {
        let control = FakeControl()
        control.waitingUpdate = ExtensionUpdate(from: "0.2.1", to: "0.2.2")
        var saved = StoredSettings()
        saved.mode = .tor
        let engine = ProxyEngine(control: control, store: MemoryStore(saved))
        await engine.resume()
        let old = control.link
        try await engine.finishUpdate()
        #expect(control.activations == [false, true])
        #expect(control.enabled == [true, true])
        #expect(old.closed)
        #expect(control.link !== old)
        guard case .configure = control.link.commands.first else {
            Issue.record("the new extension wasn't configured")
            return
        }
        #expect(await engine.current.pendingUpdate == nil)
        control.link.push(ExtensionState(status: .on, trunk: Trunk(bridge: .snowflake, guardRelay: nil), apps: []))
        try await eventually { await engine.current.status == .on }
    }

    @Test func aWaitingUpdateDoesNotStopReconnecting() async throws {
        let control = FakeControl()
        let update = ExtensionUpdate(from: "0.2.1", to: "0.2.2")
        control.waitingUpdate = update
        var saved = StoredSettings()
        saved.mode = .tor
        let engine = ProxyEngine(control: control, store: MemoryStore(saved), retryDelay: .zero)
        await engine.resume()
        let running = control.link
        control.failingConnects = 2
        // The running extension restarts: the app reaches it again, still
        // without replacing it.
        running.close()
        try await eventually { control.failingConnects == 0 }
        #expect(control.activations == [false])
        #expect(await engine.current.pendingUpdate == update)
    }

    @Test func finishingAnUpdateWaitsForTheNewExtensionToAnswer() async throws {
        let control = FakeControl()
        control.waitingUpdate = ExtensionUpdate(from: "0.2.1", to: "0.2.2")
        var saved = StoredSettings()
        saved.mode = .tor
        let engine = ProxyEngine(control: control, store: MemoryStore(saved), retryDelay: .zero)
        await engine.resume()
        // The new extension's Mach service lags behind its first launch.
        control.failingConnects = 3
        try await engine.finishUpdate()
        #expect(control.failingConnects == 0)
        guard case .configure = control.link.commands.first else {
            Issue.record("the new extension wasn't configured")
            return
        }
        control.link.push(ExtensionState(status: .on, trunk: Trunk(), apps: []))
        try await eventually { await engine.current.status == .on }
        #expect(await engine.current.pendingUpdate == nil)
    }

    @Test func finishingAnUpdateInDirectOnlyReplaces() async throws {
        let control = FakeControl()
        control.waitingUpdate = ExtensionUpdate(from: "0.2.1", to: "0.2.2")
        var saved = StoredSettings()
        saved.mode = .tor
        let store = MemoryStore(saved)
        let engine = ProxyEngine(control: control, store: store)
        await engine.resume()
        try await engine.setMode(.direct)
        #expect(await engine.current.pendingUpdate != nil)
        try await engine.finishUpdate()
        #expect(control.activations == [false, true])
        #expect(control.enabled == [true, false])
        #expect(await engine.current.pendingUpdate == nil)
        #expect(await engine.current.status == .off)
    }
}
