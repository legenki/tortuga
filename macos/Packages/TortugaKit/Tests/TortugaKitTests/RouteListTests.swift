import Foundation
import Testing
@testable import TortugaKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let relay = Relay(nickname: "r", country: "DE", address: "185.220.101.1")

private func route(_ id: String, secondsAgo: Double) -> AppRoute {
    AppRoute(app: AppID(id), middle: relay, exit: relay, connections: 1, lastActive: now.addingTimeInterval(-secondsAgo))
}

@Test func sortsByLastActivityAndFoldsIdleApps() {
    let list = RouteList(
        apps: [route("old", secondsAgo: 300), route("new", secondsAgo: 5), route("sleepy", secondsAgo: 601)],
        torApps: [AppID("old"), AppID("new"), AppID("sleepy")],
        now: now
    )
    #expect(list.active.map(\.id) == ["new", "old"])
    #expect(list.idle.map(\.id) == ["sleepy"])
    #expect(list.waiting.isEmpty)
}

@Test func listedAppsWithoutTrafficWait() {
    let list = RouteList(apps: [route("safari", secondsAgo: 2)],
                         torApps: [AppID("safari"), AppID("firefox")], now: now)
    #expect(list.active.map(\.id) == ["safari"])
    #expect(list.waiting == [AppID("firefox")])
}

@Test func routesOfUnlistedAppsAreLeftOut() {
    let list = RouteList(apps: [route("mail", secondsAgo: 1), route("safari", secondsAgo: 2)],
                         torApps: [AppID("safari")], now: now)
    #expect(list.active.map(\.id) == ["safari"])
}
