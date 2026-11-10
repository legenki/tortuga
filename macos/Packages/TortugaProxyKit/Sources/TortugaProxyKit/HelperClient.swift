import Foundation

/// How the client reaches the helper: a process's pipes in the extension,
/// a fake in tests.
public protocol HelperTransport: Sendable {
    func write(_ data: Data) async throws
    /// Bytes from the helper as they arrive; finishes when it exits.
    var incoming: AsyncStream<Data> { get }
}

public enum HelperError: Error, Equatable, LocalizedError {
    case remote(code: String, message: String)
    /// The helper exited (or its pipe closed) before answering.
    case gone

    public var errorDescription: String? {
        switch self {
        case .remote(_, let message): message
        case .gone: "Tor stopped"
        }
    }
}

/// Requests with replies matched by id; everything without an id is an event.
public actor HelperClient {
    public nonisolated let events: AsyncStream<HelperEvent>
    private let eventFeed: AsyncStream<HelperEvent>.Continuation
    private let transport: any HelperTransport
    private var nextID: UInt64 = 1
    private var waiting: [UInt64: AsyncThrowingStream<HelperEvent, Error>.Continuation] = [:]
    private var gone = false
    private var reader: Task<Void, Never>?

    public init(transport: any HelperTransport) {
        self.transport = transport
        (events, eventFeed) = AsyncStream.makeStream(of: HelperEvent.self)
        Task { await self.startReading() }
    }

    public func request(_ request: HelperRequest) async throws -> HelperEvent {
        guard !gone else { throw HelperError.gone }
        let id = nextID
        nextID += 1
        let (stream, reply) = AsyncThrowingStream<HelperEvent, Error>.makeStream()
        waiting[id] = reply
        try await transport.write(Framing.encode(request.encoded(id: id)))
        for try await event in stream {
            if case .error(let code, let message) = event { throw HelperError.remote(code: code, message: message) }
            return event
        }
        throw HelperError.gone
    }

    private func startReading() {
        guard reader == nil else { return }
        let incoming = transport.incoming
        reader = Task { [weak self] in
            var frames = FrameReader()
            for await chunk in incoming {
                for frame in frames.push(chunk) {
                    guard let message = HelperMessage.parse(frame) else { continue }
                    await self?.deliver(message)
                }
            }
            await self?.closed()
        }
    }

    private func deliver(_ message: HelperMessage) {
        if let id = message.id, let reply = waiting.removeValue(forKey: id) {
            reply.yield(message.event)
            reply.finish()
        } else {
            eventFeed.yield(message.event)
        }
    }

    private func closed() {
        gone = true
        for reply in waiting.values { reply.finish(throwing: HelperError.gone) }
        waiting.removeAll()
        eventFeed.finish()
    }
}
