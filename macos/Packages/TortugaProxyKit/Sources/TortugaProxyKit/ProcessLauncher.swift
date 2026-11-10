import Foundation

/// Starts the real helper with its data under `dataDirectory` and lyrebird
/// from `ptDir`.
public struct ProcessLauncher: HelperLauncher {
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public func launch(helperPath: String, ptDir: String) throws -> any HelperTransport {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: helperPath])
        }
        return try ProcessTransport(executable: URL(fileURLWithPath: helperPath),
                                    environment: ["TORTUGA_DATA_DIR": dataDirectory.path, "TORTUGA_PT_DIR": ptDir])
    }
}
