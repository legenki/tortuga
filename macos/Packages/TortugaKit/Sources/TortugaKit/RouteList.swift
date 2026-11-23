import Foundation

/// The Tor list's rows: listed apps with traffic in the last ten minutes
/// (most recent first), listed apps with older traffic, and listed apps that
/// haven't connected yet. Routes of apps no longer listed are left out.
public struct RouteList: Sendable, Equatable {
    public static let idleAfter: TimeInterval = 600

    public var active: [AppRoute]
    public var idle: [AppRoute]
    public var waiting: [AppID]

    public init(apps: [AppRoute], torApps: [AppID], now: Date) {
        let listed = Set(torApps)
        let routed = apps
            .filter { listed.contains($0.app) }
            .sorted { $0.lastActive > $1.lastActive }
        active = routed.filter { now.timeIntervalSince($0.lastActive) <= Self.idleAfter }
        idle = routed.filter { now.timeIntervalSince($0.lastActive) > Self.idleAfter }
        waiting = torApps.filter { app in !apps.contains { $0.app == app } }
    }
}
