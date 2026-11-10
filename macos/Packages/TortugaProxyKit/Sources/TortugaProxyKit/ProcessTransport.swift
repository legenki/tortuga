import Foundation

/// The helper as a child process, spoken to over its stdin and stdout.
public final class ProcessTransport: HelperTransport, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()

    /// `onStandardError` gets the helper's stderr, line by line.
    public init(executable: URL, environment: [String: String] = [:],
                onStandardError: (@Sendable (String) -> Void)? = nil) throws {
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
        if let onStandardError {
            process.standardError = errors
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { onStandardError(String(line)) }
            }
        }
        process.terminationHandler = { process in
            onStandardError?("exited with status \(process.terminationStatus)")
            feed.finish()
        }
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
