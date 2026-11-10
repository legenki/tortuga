import Foundation
import os
import TortugaKit
import TortugaProxyKit

let proxyLog = Logger(subsystem: "org.tortuga.app", category: "proxy")

/// The extension process's one core, shared by both providers and XPC.
enum Shared {
    static let core = ProxyCore(launcher: ProcessLauncher(dataDirectory: dataDirectory))
    static let names = NameCache()

    /// The helper's Arti state, in the extension's container.
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "tortuga-helper")
    }

    static func handle(_ command: ExtensionCommand) async -> ExtensionReply {
        do {
            switch command {
            case .configure(let configuration):
                await core.configure(configuration)
            case .restart:
                await core.restart()
            case .newCircuit(let app):
                try await core.newCircuit(app: app)
            case .fetchBridgeLines(let kind):
                return .lines(try await core.fetchBridgeLines(kind))
            }
            return .ok
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// For values NetworkExtension hands us that Swift can't see are safe to
/// pass to a task (flows are thread-safe objects).
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
