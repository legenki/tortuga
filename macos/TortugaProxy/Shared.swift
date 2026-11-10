import Foundation
import os
import TortugaKit
import TortugaProxyKit

let proxyLog = Logger(subsystem: "org.tortuga.app", category: "proxy")

/// The extension process's one core, shared by both providers and XPC.
enum Shared {
    static let core = ProxyCore(launcher: ProcessLauncher(dataDirectory: dataDirectory) { line in
        proxyLog.notice("helper: \(line, privacy: .public)")
    })

    /// Logs each status change (no host names: statuses and app counts only).
    static func watchStatus() {
        Task {
            var last: Status?
            for await state in await core.states() where state.status != last {
                last = state.status
                proxyLog.notice("status: \(String(describing: state.status), privacy: .public), apps: \(state.apps.count)")
            }
        }
    }
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
