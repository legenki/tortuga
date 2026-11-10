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
            if let link {
                try check(await link.send(.configure(configuration())))
            } else {
                try await attach()
            }
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
