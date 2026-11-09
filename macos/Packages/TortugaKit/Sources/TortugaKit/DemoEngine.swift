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
