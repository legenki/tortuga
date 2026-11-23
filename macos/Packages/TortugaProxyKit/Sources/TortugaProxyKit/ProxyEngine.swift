import Foundation
import TortugaKit

/// The system side the app drives: the system extension, its two network
/// configurations, and the XPC connection to it. Real in the app, a fake in tests.
public protocol ProxyControl: Sendable {
    /// Install or update the extension. Calls `onNeedsApproval` when macOS
    /// waits for the user, and returns once it's active. When the app holds a
    /// different version than the one running, `replace: false` leaves the
    /// running one and returns `.updateWaiting`: replacing it stops the
    /// proxies, and traffic goes out directly until the new one starts.
    func activate(replace: Bool, onNeedsApproval: @escaping @Sendable () -> Void) async throws -> ActivationOutcome
    /// Turn both proxies on (with `configuration`) or off.
    func setEnabled(_ on: Bool, configuration: ProxyConfiguration) async throws
    func connect() async throws -> any ExtensionLink
    /// tortuga-helper and pt/ in this app's bundle.
    var helperPaths: (helper: String, pt: String) { get }
}

public enum ActivationOutcome: Sendable, Equatable {
    case active
    /// The running extension was kept; this update waits.
    case updateWaiting(ExtensionUpdate)
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
    static let extensionGone = "Tortuga's network extension isn't running"

    private let control: any ProxyControl
    private let store: any SettingsStore
    private var settings: StoredSettings
    private var remote = ExtensionState.idle
    private var local: Status = .off
    private var pendingUpdate: ExtensionUpdate?
    private var link: (any ExtensionLink)?
    private var linkTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var reattach: Task<Void, Never>?
    /// Reconnections since the extension last sent a state: a link that keeps
    /// dropping at once means the extension is gone.
    private var reconnects = 0
    /// Between tries to reach the extension: its Mach service can lag behind
    /// the proxy session starting, or come back a moment after it restarts.
    private let retryDelay: Duration
    static let attachAttempts = 10

    /// `installedBrowsers`: the first Tor list, asked for only when the
    /// settings have none yet.
    public init(control: any ProxyControl, store: any SettingsStore,
                installedBrowsers: @Sendable () -> [AppID] = { [] },
                retryDelay: Duration = .milliseconds(500)) {
        self.retryDelay = retryDelay
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

    public var current: EngineState {
        var state = EngineState()
        state.mode = settings.mode
        state.bridges = BridgeSettings(selected: settings.bridge, lines: settings.lines)
        state.torApps = settings.torApps ?? []
        state.pendingUpdate = pendingUpdate
        if link != nil {
            state.status = remote.status
            state.trunk = remote.trunk
            state.apps = remote.apps
            // Not the listed apps, nor their helpers.
            let listed = Set((settings.torApps ?? []).map(\.id))
            state.seenDirect = remote.seenDirect.filter { TorAppMatcher.match($0, in: listed) == nil }.map { AppID($0) }
        } else {
            state.status = local
        }
        return state
    }

    /// Bring Tor back at launch if it was on. The extension that's running
    /// carries the traffic now, so an update to it waits for the user.
    public func resume() async {
        if settings.mode == .tor { try? await turnOn(replace: false) }
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
        // Nothing goes through the extension in Direct, so switching to Tor
        // can replace it without a gap.
        if mode == .tor { try await turnOn(replace: current.status == .off) } else { await turnOff() }
    }

    public func restart() async throws {
        guard settings.mode == .tor else { throw EngineError("Switch to Tor first") }
        if let link { try check(await link.send(.restart)) } else { try await turnOn(replace: false) }
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

    public func finishUpdate() async throws {
        guard pendingUpdate != nil else { return }
        guard settings.mode == .tor else {
            // The proxies are off: replace now, they start with Tor.
            _ = try await control.activate(replace: true, onNeedsApproval: {})
            pendingUpdate = nil
            publish()
            return
        }
        // The old extension's link ends with it; that's not a lost
        // connection to reach again, so let go of it first.
        detach()
        try await turnOn(replace: true, step: "Updating Tortuga's network extension")
    }

    // MARK: On and off

    private func turnOn(replace: Bool, step: String = "Starting Tortuga's network extension") async throws {
        local = .starting(step: step, progress: 0)
        publish()
        do {
            let outcome = try await control.activate(replace: replace, onNeedsApproval: { [weak self] in
                Task { await self?.waitingForApproval() }
            })
            switch outcome {
            case .active: pendingUpdate = nil
            case .updateWaiting(let update): pendingUpdate = update
            }
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
        detach()
        try? await control.setEnabled(false, configuration: configuration())
        local = .off
        publish()
    }

    /// Let go of the extension on purpose: no reconnecting.
    private func detach() {
        reattach?.cancel()
        reattach = nil
        dropLink()
        reconnects = 0
        remote = .idle
    }

    /// Connect to the extension and send it the settings, trying again for a
    /// few seconds: right after the proxy starts (or the app relaunches) its
    /// Mach service may not answer yet.
    private func attach() async throws {
        var lastError: (any Error)?
        for attempt in 1...Self.attachAttempts {
            if attempt > 1 { try? await Task.sleep(for: retryDelay) }
            // A reconnection that was called off (Direct, or an update
            // replacing the extension) stops here.
            try Task.checkCancellation()
            guard settings.mode == .tor else { return }
            do {
                try await connectOnce()
                return
            } catch {
                lastError = error
                dropLink()
            }
        }
        throw lastError ?? EngineError(Self.extensionGone)
    }

    private func connectOnce() async throws {
        let link = try await control.connect()
        self.link = link
        // Listen first: configuring can restart Tor, and its progress should show.
        let states = link.states
        linkTask = Task { [weak self] in
            for await state in states { await self?.received(state) }
            await self?.lost(link)
        }
        try check(await link.send(.configure(configuration())))
    }

    private func dropLink() {
        linkTask?.cancel()
        linkTask = nil
        link?.close()
        link = nil
    }

    private func waitingForApproval() {
        guard link == nil else { return }
        local = .failed(reason: Status.allowExtensionReason)
        publish()
    }

    private func received(_ state: ExtensionState) {
        remote = state
        reconnects = 0
        publish()
    }

    private func lost(_ gone: any ExtensionLink) {
        guard let link, link === gone else { return }
        self.link = nil
        linkTask = nil
        remote = .idle
        guard settings.mode == .tor else {
            local = .off
            publish()
            return
        }
        // The extension restarted or the connection dropped: reach it again,
        // unless it keeps dropping without ever answering.
        reconnects += 1
        guard reconnects <= Self.attachAttempts else {
            local = .failed(reason: Self.extensionGone)
            publish()
            return
        }
        local = .starting(step: "Reconnecting to Tortuga's network extension", progress: 0)
        publish()
        reattach?.cancel()
        reattach = Task { [weak self] in await self?.reconnect() }
    }

    private func reconnect() async {
        guard settings.mode == .tor, link == nil else { return }
        do {
            try await attach()
        } catch {
            guard !Task.isCancelled, settings.mode == .tor, link == nil else { return }
            local = .failed(reason: Self.extensionGone)
            publish()
        }
    }

    // MARK: Helpers

    private func configuration() -> ProxyConfiguration {
        ProxyConfiguration(bridge: settings.bridge, lines: settings.lines, torApps: (settings.torApps ?? []).map(\.id),
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
