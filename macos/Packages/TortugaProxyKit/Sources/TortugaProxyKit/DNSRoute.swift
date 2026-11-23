import TortugaKit

/// Where a DNS query goes. A DNS flow can't be handed back to macOS
/// (returning false drops it, spike Q6), so queries that shouldn't go
/// through Tor are forwarded to the system's resolver.
public enum DNSRoute {
    /// The resolver to forward to, or nil to answer through Tor. Until the
    /// Tor list arrives (`torApps` nil), only our own programs ask the system:
    /// the rest are answered through Tor, which fails while it isn't ready.
    /// A listed app's child process (found through `ancestors`, the parent's,
    /// grandparent's, … signing identifiers, asked only when the app itself
    /// isn't listed) counts as the app.
    public static func upstream(app: String, ancestors: () -> [String] = { [] }, torApps: Set<String>?,
                                own: Set<String>, system: String) -> String? {
        if own.contains(app) { return system }
        guard let torApps else { return nil }
        return FlowRouter.listedApp(app, ancestors: ancestors, in: torApps) == nil ? system : nil
    }
}
