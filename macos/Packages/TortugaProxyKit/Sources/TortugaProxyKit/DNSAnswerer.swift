import Foundation

/// One DNS query in, one answer out. Every query gets an answer (spike Q6):
/// through Tor, empty, or SERVFAIL. nil only for bytes that aren't a query.
public enum DNSAnswerer {
    /// How long an address query waits for Tor before it fails. mDNSResponder
    /// caches an answer without records for at least 75 s, whatever SOA comes
    /// with it, but caches nothing while no answer comes: so a query asked
    /// while Tor builds circuits waits, and is answered as soon as Tor is up.
    public static let hold: Duration = .seconds(30)
    static let poll: Duration = .milliseconds(100)

    public static func answer(_ query: Data, torReady: @Sendable () -> Bool, hold: Duration = hold,
                              names: NameCache, now: Date = .now,
                              resolve: (String) async throws -> [String]) async -> Data? {
        guard let q = DNSMessage.parseQuery(query) else { return nil }
        guard DNSType.resolvable(q.question.type) else { return DNSMessage.empty(q) }
        guard await waitFor(torReady, upTo: hold) else { return DNSMessage.serverFailure(q) }
        do {
            let addresses = try await resolve(q.question.name)
            for address in addresses { names.record(ip: address, name: q.question.name, now: now) }
            return DNSMessage.answer(q, addresses: addresses)
        } catch {
            return DNSMessage.serverFailure(q)
        }
    }

    /// True as soon as `ready` is, false if it isn't within `limit`.
    private static func waitFor(_ ready: () -> Bool, upTo limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !ready() {
            let left = deadline - ContinuousClock.now
            guard left > .zero, !Task.isCancelled else { return false }
            try? await Task.sleep(for: min(poll, left))
        }
        return true
    }
}
