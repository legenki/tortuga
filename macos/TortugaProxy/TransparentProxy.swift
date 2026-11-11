import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// Every TCP and UDP flow off this Mac, except local networks (excluded in
/// the settings): to Tor by the app's own circuit, straight out for
/// exceptions and our own programs, or closed.
final class TransparentProxy: NETransparentProxyProvider {
    /// Loopback, private, link-local, multicast: never offered to us.
    static let localNetworks: [(String, Int)] = [
        ("127.0.0.0", 8), ("10.0.0.0", 8), ("172.16.0.0", 12), ("192.168.0.0", 16), ("169.254.0.0", 16),
        ("224.0.0.0", 4), ("255.255.255.255", 32), ("::1", 128), ("fe80::", 10), ("fc00::", 7), ("ff00::", 8),
    ]

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]
        // DNS (port 53, any address) is left to the DNS proxy: the transparent
        // proxy sees flows first, and DNS it took would never reach the DNS proxy.
        let dns = ["0.0.0.0", "::"].map { address in
            NENetworkRule(remoteNetworkEndpoint: .hostPort(host: NWEndpoint.Host(address), port: 53), remotePrefix: 0,
                          localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound)
        }
        settings.excludedNetworkRules = dns + Self.localNetworks.map { address, prefix in
            NENetworkRule(remoteNetworkEndpoint: .hostPort(host: NWEndpoint.Host(address), port: 0), remotePrefix: prefix,
                          localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound)
        }
        let configuration = ProxyConfiguration(providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration)
        let started = Unchecked(value: completionHandler)
        setTunnelNetworkSettings(settings) { error in
            if let error { proxyLog.error("proxy settings failed: \(error.localizedDescription, privacy: .public)") }
            Task {
                if let configuration { await Shared.core.configure(configuration) }
                await Shared.core.start()
            }
            started.value(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let done = Unchecked(value: completionHandler)
        Task {
            await Shared.core.stop()
            done.value()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let snapshot = Shared.core.routes.snapshot()
        var ip = ""
        var port = 0
        if let tcp = flow as? NEAppProxyTCPFlow, case .hostPort(let host, let p) = tcp.remoteFlowEndpoint {
            ip = Self.address(host)
            port = Int(p.rawValue)
        }
        let info = FlowInfo(app: flow.metaData.sourceAppSigningIdentifier, remoteHost: flow.remoteHostname,
                            remoteIP: ip, port: port, isUDP: flow is NEAppProxyUDPFlow)
        let decision = FlowRouter.decide(info, snapshot.state, names: Shared.names)
        let kind: String = switch decision { case .direct: "direct"; case .refuse: "refuse"; case .tor: "tor" }
        proxyLog.notice("flow \(info.isUDP ? "udp" : "tcp", privacy: .public) from \(info.app, privacy: .public): \(kind, privacy: .public), by name: \(info.remoteHost != nil)")
        switch decision {
        case .direct:
            return false
        case .refuse:
            Self.refuse(flow)
            return true
        case .tor(let host, let port, let isolation):
            guard let socksPort = snapshot.socksPort, let tcp = flow as? NEAppProxyTCPFlow else {
                Self.refuse(flow)
                return true
            }
            TCPRelay(flow: tcp, host: host, port: port, isolation: isolation, socksPort: socksPort).start()
            return true
        }
    }

    static func refuse(_ flow: NEAppProxyFlow) {
        let error = NEAppProxyFlowError(.refused)
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }

    static func address(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }
}
