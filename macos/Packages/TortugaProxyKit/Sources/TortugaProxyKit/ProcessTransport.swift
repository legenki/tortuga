import Foundation

/// The helper as a child process, spoken to over its stdin and stdout.
public final class ProcessTransport: HelperTransport, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    public init(executable: URL, environment: [String: String] = [:]) throws {
        let (stream, feed) = AsyncStream.makeStream(of: Data.self)
        incoming = stream
        process.executableURL = executable
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        process.terminationHandler = { _ in feed.finish() }
        try process.run()
    }

    public func write(_ data: Data) async throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public var isRunning: Bool { process.isRunning }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}
