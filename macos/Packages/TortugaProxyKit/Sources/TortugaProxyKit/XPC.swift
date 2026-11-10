import Foundation
import TortugaKit

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
