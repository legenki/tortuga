import Foundation

/// One DNS query in, one answer out. Every query gets an answer (spike Q6):
/// through Tor, empty, or SERVFAIL. nil only for bytes that aren't a query.
public enum DNSAnswerer {
    public static func answer(_ query: Data, torReady: Bool, names: NameCache, now: Date = .now,
                              resolve: (String) async throws -> [String]) async -> Data? {
        guard let q = DNSMessage.parseQuery(query) else { return nil }
        guard torReady else { return DNSMessage.serverFailure(q) }
        guard DNSType.resolvable(q.question.type) else { return DNSMessage.empty(q) }
        do {
            let addresses = try await resolve(q.question.name)
            for address in addresses { names.record(ip: address, name: q.question.name, now: now) }
            return DNSMessage.answer(q, addresses: addresses)
        } catch {
            return DNSMessage.serverFailure(q)
        }
    }
}
