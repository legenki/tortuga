import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// Every DNS query on this Mac. Each is answered here, through Tor or with a
/// failure; returning false would drop it (spike Q6).
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
        let boxed = Unchecked(value: udp)
        udp.open(withLocalFlowEndpoint: nil) { error in
            if error == nil { Self.serve(boxed) }
        }
        return true
    }

    private static func serve(_ boxed: Unchecked<NEAppProxyUDPFlow>) {
        boxed.value.readDatagrams { datagrams, error in
            guard let datagrams, error == nil, !datagrams.isEmpty else {
                boxed.value.closeReadWithError(nil)
                boxed.value.closeWriteWithError(nil)
                return
            }
            for (query, endpoint) in datagrams {
                let sender = Unchecked(value: endpoint)
                Task {
                    let ready = Shared.core.routes.snapshot().state.torReady
                    let answer = await DNSAnswerer.answer(query, torReady: ready, names: Shared.names) { name in
                        try await Shared.core.resolve(name)
                    }
                    if let answer { boxed.value.writeDatagrams([(answer, sender.value)]) { _ in } }
                }
            }
            serve(boxed)
        }
    }
}
