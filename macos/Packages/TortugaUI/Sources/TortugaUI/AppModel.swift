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
