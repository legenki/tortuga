import Foundation

/// Starts the real helper with its data under `dataDirectory` and lyrebird
/// from `ptDir`.
public struct ProcessLauncher: HelperLauncher {
    public let dataDirectory: URL
    public let onStandardError: (@Sendable (String) -> Void)?

    public init(dataDirectory: URL, onStandardError: (@Sendable (String) -> Void)? = nil) {
        self.dataDirectory = dataDirectory
        self.onStandardError = onStandardError
    }

    public func launch(helperPath: String, ptDir: String) throws -> any HelperTransport {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: helperPath])
        }
        return try ProcessTransport(executable: URL(fileURLWithPath: helperPath),
                                    environment: ["TORTUGA_DATA_DIR": dataDirectory.path, "TORTUGA_PT_DIR": ptDir],
                                    onStandardError: onStandardError)
    }
}
