import Foundation
import NetworkExtension

/// Spike only: logs who sends DNS and lets it through (returns false).
final class SpikeDNSProxy: NEDNSProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        spikeLog.notice("spike: DNS proxy started")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        spikeLog.notice("spike: DNS proxy stopped (\(reason.rawValue))")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let kind = flow is NEAppProxyTCPFlow ? "tcp" : "udp"
        spikeLog.notice("spike: dns \(kind, privacy: .public) app=\(flow.metaData.sourceAppSigningIdentifier, privacy: .public)")
        return false
    }
}
