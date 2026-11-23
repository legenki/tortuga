import Synchronization

/// What the providers read for every flow, synchronously: whether Tor is
/// ready, the Tor list, our own programs, and the helper's SOCKS port.
/// `ProxyCore` keeps it current. Until it has the Tor list, it has none
/// (nil), and only our own and local traffic goes out.
public final class RouteTable: Sendable {
    public struct Snapshot: Sendable {
        public var state: RouterState
        public var socksPort: Int?
    }

    private let box = Mutex(Snapshot(state: RouterState(torReady: false, torApps: nil, own: ProxyCore.ownIDs), socksPort: nil))

    public init() {}

    public func update(state: RouterState, socksPort: Int?) {
        box.withLock { $0 = Snapshot(state: state, socksPort: socksPort) }
    }

    public func snapshot() -> Snapshot { box.withLock { $0 } }
}
