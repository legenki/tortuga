import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// Every DNS query on this Mac. Each is answered here, through Tor or with a
/// failure; returning false would drop it (spike Q6). Queries from our own
/// programs (the helper, lyrebird) go to the system's resolver instead:
/// Snowflake has to find its broker before Tor can start.
final class DNSProxy: NEDNSProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let udp = flow as? NEAppProxyUDPFlow else {
            // DNS over TCP: closed; resolvers retry over UDP.
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return true
        }
        let app = flow.metaData.sourceAppSigningIdentifier
        let own = ProxyCore.ownIDs.contains(app)
        let upstream = own ? systemDNSSettings?.flatMap(\.servers).first : nil
        proxyLog.notice("dns flow from \(app, privacy: .public), own: \(own), upstream: \(upstream ?? "-", privacy: .public), system DNS: \(String(describing: self.systemDNSSettings?.flatMap(\.servers)), privacy: .public)")
        let boxed = Unchecked(value: udp)
        udp.open(withLocalFlowEndpoint: nil) { error in
            if let error { proxyLog.error("dns flow didn't open: \(error.localizedDescription, privacy: .public)") }
            if error == nil { Self.serve(boxed, upstream: upstream) }
        }
        return true
    }

    private static func serve(_ boxed: Unchecked<NEAppProxyUDPFlow>, upstream: String?) {
        boxed.value.readDatagrams { datagrams, error in
            guard let datagrams, error == nil, !datagrams.isEmpty else {
                boxed.value.closeReadWithError(nil)
                boxed.value.closeWriteWithError(nil)
                return
            }
            for (query, endpoint) in datagrams {
                let sender = Unchecked(value: endpoint)
                Task {
                    let answer: Data?
                    if let upstream {
                        answer = await forward(query, to: upstream)
                    } else {
                        let ready = Shared.core.routes.snapshot().state.torReady
                        answer = await DNSAnswerer.answer(query, torReady: ready, names: Shared.names) { name in
                            try await Shared.core.resolve(name)
                        }
                    }
                    proxyLog.notice("dns answer: \(answer.map { "rcode \($0[3] & 0x0F), \($0.count) bytes" } ?? "none", privacy: .public) via \(upstream == nil ? "tor" : "system", privacy: .public)")
                    if let answer {
                        boxed.value.writeDatagrams([(answer, sender.value)]) { error in
                            if let error { proxyLog.error("dns write failed: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            }
            serve(boxed, upstream: upstream)
        }
    }

    /// Ask the system's resolver directly (the provider's own traffic isn't
    /// proxied). nil after 5 s or on any error.
    private static func forward(_ query: Data, to server: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let once = Once(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: query, completion: .contentProcessed { _ in })
                    connection.receiveMessage { data, _, _, _ in
                        once.resume(data)
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    once.resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.resume(nil)
                connection.cancel()
            }
        }
    }
}

/// Resumes a continuation once, whichever callback comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

    func resume(_ value: Data?) {
        let pending = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
