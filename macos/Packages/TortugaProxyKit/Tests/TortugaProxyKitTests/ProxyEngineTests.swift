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
