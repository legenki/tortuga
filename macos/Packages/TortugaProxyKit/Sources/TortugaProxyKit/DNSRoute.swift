import TortugaKit

/// Where a DNS query goes. A DNS flow can't be handed back to macOS
/// (returning false drops it, spike Q6), so queries that shouldn't go
/// through Tor are forwarded to the system's resolver.
public enum DNSRoute {
    /// The resolver to forward to, or nil to answer through Tor.
    public static func upstream(app: String, torApps: Set<String>, own: Set<String>, system: String) -> String? {
        if own.contains(app) || TorAppMatcher.match(app, in: torApps) == nil { return system }
        return nil
    }
}
