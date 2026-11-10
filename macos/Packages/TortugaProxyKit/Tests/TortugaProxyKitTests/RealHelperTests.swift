import Foundation
import Testing
@testable import TortugaProxyKit

/// The helper built by `cargo build --release`, if it's there.
private let helper: URL? = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // Tests/…/file → package
        .appending(path: "../../../helper/target/release/tortuga-helper").standardizedFileURL
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

@Test(.enabled(if: helper != nil, "build the helper first: cd helper && cargo build --release"))
func theRealHelperSaysHelloWithApps() async throws {
    let data = FileManager.default.temporaryDirectory.appending(path: "tortuga-proxykit-\(UUID().uuidString)")
    let transport = try ProcessTransport(executable: helper!, environment: ["TORTUGA_DATA_DIR": data.path])
    let client = HelperClient(transport: transport)
    guard case .hello(_, let features) = try await client.request(.hello) else {
        Issue.record("no hello")
        return
    }
    #expect(features.contains("apps"))
    await #expect(throws: HelperError.remote(code: "not_running", message: "Tor is off")) {
        try await client.request(.resolve("example.com"))
    }
    transport.terminate()
}
