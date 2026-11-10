import Foundation
import Network
import NetworkExtension
import os

let spikeLog = Logger(subsystem: "org.tortuga.app", category: "spike")

/// Spike only: logs every flow it's offered and passes it through. Host names
/// are logged publicly here and nowhere else; the real provider never logs them.
final class SpikeTransparentProxy: NETransparentProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]
        setTunnelNetworkSettings(settings) { error in
            spikeLog.notice("spike: transparent proxy started, settings error: \(String(describing: error), privacy: .public)")
            SpikeHelperCheck.run()
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        spikeLog.notice("spike: transparent proxy stopped (\(reason.rawValue))")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let app = flow.metaData.sourceAppSigningIdentifier
        let host = flow.remoteHostname ?? "-"
        let kind = flow is NEAppProxyTCPFlow ? "tcp" : "udp"
        var endpoint = "-"
        if let tcp = flow as? NEAppProxyTCPFlow { endpoint = "\(tcp.remoteFlowEndpoint)" }
        spikeLog.notice("spike: flow \(kind, privacy: .public) app=\(app, privacy: .public) host=\(host, privacy: .public) endpoint=\(endpoint, privacy: .public)")
        return false
    }
}
