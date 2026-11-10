import Synchronization

/// What the providers read for every flow, synchronously: whether Tor is
/// ready, the exceptions, our own programs, and the helper's SOCKS port.
/// `ProxyCore` keeps it current.
public final class RouteTable: Sendable {
    public struct Snapshot: Sendable {
        public var state: RouterState
        public var socksPort: Int?
    }

    private let box = Mutex(Snapshot(state: RouterState(torReady: false, exceptions: [], own: ProxyCore.ownIDs), socksPort: nil))

    public init() {}

    public func update(state: RouterState, socksPort: Int?) {
        box.withLock { $0 = Snapshot(state: state, socksPort: socksPort) }
    }

    public func snapshot() -> Snapshot { box.withLock { $0 } }
}
