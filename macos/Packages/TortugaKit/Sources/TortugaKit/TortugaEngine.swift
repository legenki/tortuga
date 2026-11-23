import Foundation

/// What the interface needs from whatever runs Tor: a stream of states and
/// commands. DemoEngine and ProxyEngine implement it.
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
    /// Send an app through Tor from its next connection.
    func addTorApp(_ app: AppID) async throws
    /// The app connects directly again.
    func removeTorApp(_ app: AppID) async throws
    /// Replace the running network extension with the waiting update
    /// (`EngineState.pendingUpdate`), and start the proxies again.
    func finishUpdate() async throws
}

/// An engine's refusal, in words to show the user as they are.
public struct EngineError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
