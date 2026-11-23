import Foundation
import NetworkExtension
import SystemExtensions
import os
import TortugaKit
import TortugaProxyKit

private let log = Logger(subsystem: "org.tortuga.app", category: "app")

/// The real ProxyControl: the system extension, its two network
/// configurations, and XPC to it.
final class SystemProxyControl: ProxyControl, @unchecked Sendable {
    static let extensionID = "org.tortuga.app.proxy"

    var helperPaths: (helper: String, pt: String) {
        let contents = Bundle.main.bundleURL
            .appending(path: "Contents/Library/SystemExtensions/\(Self.extensionID).systemextension/Contents")
        return (contents.appending(path: "MacOS/tortuga-helper").path, contents.appending(path: "Resources/pt").path)
    }

    func activate(replace: Bool, onNeedsApproval: @escaping @Sendable () -> Void) async throws -> ActivationOutcome {
        try await Activation(replace: replace, onNeedsApproval: onNeedsApproval).run()
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
///
/// Replacing a running extension stops both proxies, and macOS starts the new
/// one only after Gatekeeper has checked it (about 2 s on 2026-11-23; nothing
/// holds flows meanwhile, so they go out directly). With `replace: false` the
/// running extension is kept and the update waits for the user.
private final class Activation: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let replace: Bool
    private let onNeedsApproval: @Sendable () -> Void
    private var continuation: CheckedContinuation<ActivationOutcome, Error>?
    private var deferred: ExtensionUpdate?

    init(replace: Bool, onNeedsApproval: @escaping @Sendable () -> Void) {
        self.replace = replace
        self.onNeedsApproval = onNeedsApproval
    }

    func run() async throws -> ActivationOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ActivationOutcome, Error>) in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: SystemProxyControl.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        let update = Self.update(from: existing, to: ext)
        log.notice("extension \(update.from, privacy: .public) → \(update.to, privacy: .public): \(self.replace ? "replacing" : "waiting for the user", privacy: .public)")
        if replace { return .replace }
        deferred = update
        return .cancel
    }

    /// "0.2.1 → 0.2.2", or with builds when only the build differs.
    static func update(from old: OSSystemExtensionProperties, to new: OSSystemExtensionProperties) -> ExtensionUpdate {
        guard old.bundleShortVersion == new.bundleShortVersion else {
            return ExtensionUpdate(from: old.bundleShortVersion, to: new.bundleShortVersion)
        }
        return ExtensionUpdate(from: "\(old.bundleShortVersion) (\(old.bundleVersion))",
                               to: "\(new.bundleShortVersion) (\(new.bundleVersion))")
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onNeedsApproval()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        continuation?.resume(returning: .active)
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        // Declining the replacement ends the request with an error, but the
        // running extension is still there and active.
        if let deferred {
            log.notice("update waits: \(error.localizedDescription, privacy: .public)")
            continuation?.resume(returning: .updateWaiting(deferred))
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
