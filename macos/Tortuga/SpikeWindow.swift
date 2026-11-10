#if DEBUG
import NetworkExtension
import SwiftUI
import SystemExtensions

/// Debug only, for the spike: activate the system extension and switch its
/// two proxies on and off, showing what macOS answers.
struct SpikeWindow: View {
    @State private var lines: [String] = []
    @State private var activator: SpikeActivator?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Activate extension") {
                    let activator = SpikeActivator { line in Task { @MainActor in lines.append(line) } }
                    self.activator = activator
                    activator.activate()
                }
                Button("Enable proxies") { Task { await set(true) } }
                Button("Disable proxies") { Task { await set(false) } }
            }
            .buttonStyle(.glass)
            ScrollView {
                Text(lines.joined(separator: "\n")).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }

    private func set(_ on: Bool) async {
        do {
            try await SpikeProxies.set(on)
            lines.append("proxies \(on ? "enabled" : "disabled")")
        } catch {
            lines.append("proxies: \(error.localizedDescription)")
        }
    }
}

final class SpikeActivator: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let report: @Sendable (String) -> Void

    init(report: @escaping @Sendable (String) -> Void) { self.report = report }

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: "org.tortuga.app.proxy", queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        report("activation requested")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        report("replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        report("needs approval: System Settings → General → Login Items & Extensions")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        report("activated (result \(result.rawValue))")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        report("activation failed: \(error.localizedDescription)")
    }
}

@MainActor
enum SpikeProxies {
    static func set(_ on: Bool) async throws {
        let manager = try await NETransparentProxyManager.loadAllFromPreferences().first ?? NETransparentProxyManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "org.tortuga.app.proxy"
        proto.serverAddress = "Tortuga"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Tortuga"
        manager.isEnabled = on
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if on { try manager.connection.startVPNTunnel() } else { manager.connection.stopVPNTunnel() }

        let dns = NEDNSProxyManager.shared()
        try await dns.loadFromPreferences()
        let dnsProto = NEDNSProxyProviderProtocol()
        dnsProto.providerBundleIdentifier = "org.tortuga.app.proxy"
        dnsProto.serverAddress = "Tortuga"
        dns.providerProtocol = dnsProto
        dns.localizedDescription = "Tortuga DNS"
        dns.isEnabled = on
        try await dns.saveToPreferences()
    }
}
#endif
