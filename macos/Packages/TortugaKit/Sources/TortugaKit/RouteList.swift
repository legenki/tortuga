import Foundation

/// The Route screen's rows: active apps (most recent first), apps idle for
/// more than ten minutes, and the excepted apps.
public struct RouteList: Sendable, Equatable {
    public static let idleAfter: TimeInterval = 600

    public var active: [AppRoute]
    public var idle: [AppRoute]
    public var excepted: [AppID]

    public init(apps: [AppRoute], exceptions: [AppID], now: Date) {
        let routed = apps
            .filter { !exceptions.contains($0.app) }
            .sorted { $0.lastActive > $1.lastActive }
        active = routed.filter { now.timeIntervalSince($0.lastActive) <= Self.idleAfter }
        idle = routed.filter { now.timeIntervalSince($0.lastActive) > Self.idleAfter }
        excepted = exceptions
    }
}
