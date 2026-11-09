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
