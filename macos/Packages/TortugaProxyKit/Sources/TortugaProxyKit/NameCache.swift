import Foundation
import Synchronization

/// Names the DNS proxy answered, by address, so a flow that connects to an
/// address can still go through Tor by name. Shared by the DNS and TCP sides.
public final class NameCache: Sendable {
    /// How long a name is remembered: longer than the 60 s TTL we answer
    /// with, since apps connect a while after they look a name up.
    public static let defaultTTL: TimeInterval = 600

    private struct Entry { var name: String; var expires: Date; var order: UInt64 }
    private struct Store { var entries: [String: Entry] = [:]; var counter: UInt64 = 0 }

    private let capacity: Int
    private let store = Mutex(Store())

    public init(capacity: Int = 4096) {
        self.capacity = capacity
    }

    public func record(ip: String, name: String, ttl: TimeInterval = NameCache.defaultTTL, now: Date = .now) {
        store.withLock { s in
            s.counter += 1
            s.entries[ip] = Entry(name: name, expires: now.addingTimeInterval(ttl), order: s.counter)
            while s.entries.count > capacity, let oldest = s.entries.min(by: { $0.value.order < $1.value.order })?.key {
                s.entries[oldest] = nil
            }
        }
    }

    public func name(for ip: String, now: Date = .now) -> String? {
        store.withLock { s in
            guard let entry = s.entries[ip], entry.expires > now else { return nil }
            return entry.name
        }
    }

    public var count: Int { store.withLock { $0.entries.count } }
}
