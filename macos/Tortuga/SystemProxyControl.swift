import Foundation
import NetworkExtension
import SystemExtensions
import TortugaKit
import TortugaProxyKit

/// The real ProxyControl: the system extension, its two network
/// configurations, and XPC to it.
final class SystemProxyControl: ProxyControl, @unchecked Sendable {
    static let extensionID = "org.tortuga.app.proxy"

    var helperPaths: (helper: String, pt: String) {
        let contents = Bundle.main.bundleURL
            .appending(path: "Contents/Library/SystemExtensions/\(Self.extensionID).systemextension/Contents")
        return (contents.appending(path: "MacOS/tortuga-helper").path, contents.appending(path: "Resources/pt").path)
    }

    func activate(onNeedsApproval: @escaping @Sendable () -> Void) async throws {
        try await Activation(onNeedsApproval: onNeedsApproval).run()
    }

    func setEnabled(_ on: Bool, configuration: TortugaProxyKit.ProxyConfiguration) async throws {
        try await Self.apply(on, configuration)
    }

    func connect() async throws -> any ExtensionLink {
        guard let service = Bundle.main.object(forInfoDictionaryKey: "TortugaProxyMachService") as? String else {
            throw EngineError("Tortuga's build has no Mach service name for its extension")
        }
        return XPCLink(machServiceName: service)
    }

    @MainActor
    private static func apply(_ on: Bool, _ configuration: TortugaProxyKit.ProxyConfiguration) async throws {
        let manager = try await NETransparentProxyManager.loadAllFromPreferences().first ?? NETransparentProxyManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionID
        proto.serverAddress = "Tortuga"
        proto.providerConfiguration = try configuration.providerConfiguration()
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Tortuga"
        manager.isEnabled = on
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if on {
            if manager.connection.status != .connected { try manager.connection.startVPNTunnel() }
        } else {
            manager.connection.stopVPNTunnel()
        }

        let dns = NEDNSProxyManager.shared()
        try await dns.loadFromPreferences()
        let dnsProto = NEDNSProxyProviderProtocol()
        dnsProto.providerBundleIdentifier = extensionID
        dnsProto.serverAddress = "Tortuga"
        dns.providerProtocol = dnsProto
        dns.localizedDescription = "Tortuga DNS"
        dns.isEnabled = on
        try await dns.saveToPreferences()
    }
}

/// One activation request, as async.
private final class Activation: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let onNeedsApproval: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(onNeedsApproval: @escaping @Sendable () -> Void) {
        self.onNeedsApproval = onNeedsApproval
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: SystemProxyControl.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onNeedsApproval()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        continuation?.resume()
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
