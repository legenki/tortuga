import TortugaKit

/// Where a DNS query goes. A DNS flow can't be handed back to macOS
/// (returning false drops it, spike Q6), so queries that shouldn't go
/// through Tor are forwarded to the system's resolver.
public enum DNSRoute {
    /// The resolver to forward to, or nil to answer through Tor. Until the
    /// Tor list arrives (`torApps` nil), only our own programs ask the system:
    /// the rest are answered through Tor, which fails while it isn't ready.
    public static func upstream(app: String, torApps: Set<String>?, own: Set<String>, system: String) -> String? {
        if own.contains(app) { return system }
        guard let torApps else { return nil }
        return TorAppMatcher.match(app, in: torApps) == nil ? system : nil
    }
}
