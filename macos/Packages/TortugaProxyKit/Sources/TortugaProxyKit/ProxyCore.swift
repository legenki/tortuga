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
    /// Resolved through Tor before traffic is let through: it needs the
    /// bridge, a circuit and an exit to work, which Arti's "ready" (from its
    /// cache) doesn't promise.
    static let warmUpName = "www.torproject.org"

    public nonisolated let routes = RouteTable()
    private let launcher: any HelperLauncher
    private let retryDelay: Duration
    private let now: @Sendable () -> Date

    private var config: ProxyConfiguration?
    private var state = ExtensionState.idle
    private var client: HelperClient?
    private var watcher: Task<Void, Never>?
    private var warmer: Task<Void, Never>?
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
                setStatus(.starting(step: "Building circuits", progress: 0.95))
                warmer = Task { [weak self] in await self?.warmUp(client) }
            }
        } catch HelperError.remote(_, let message) {
            guard client === self.client else { return }
            setStatus(.failed(reason: message))
        } catch {
            // The helper went away; helperGone decides what's next.
        }
    }

    /// Hold traffic back until a lookup through Tor works, then go on.
    private func warmUp(_ client: HelperClient) async {
        while wanted, client === self.client, !Task.isCancelled {
            if (try? await client.request(.resolve(Self.warmUpName))) != nil {
                guard client === self.client else { return }
                setStatus(.on)
                return
            }
            try? await Task.sleep(for: retryDelay)
        }
    }

    private func stopHelper() {
        watcher?.cancel()
        watcher = nil
        warmer?.cancel()
        warmer = nil
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
        // This runs in the old watcher task: detach it, or startHelper's
        // stopHelper would cancel the very task doing the restart.
        watcher = nil
        setStatus(.blocked(reason: "Tor stopped"))
        guard wanted, retries < Self.maxRetries else { return }
        retries += 1
        try? await Task.sleep(for: retryDelay)
        if wanted && client == nil { await startHelper() }
    }

    // MARK: State

    private func setStatus(_ status: Status) {
        state.status = status
        if status == .off { state.trunk = Trunk() }
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
