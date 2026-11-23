import Foundation
import Testing
@testable import TortugaUI
import TortugaKit

private let guardRelay = Relay(nickname: "g", country: "DE", address: "192.0.2.1")
private let route = AppRoute(app: AppID("a"), middle: Relay(nickname: "Blåbär", country: "FR", address: "192.0.2.2"),
                             exit: Relay(nickname: "nyx", country: "SE", address: "185.220.101.4"),
                             connections: 3, lastActive: .now)

@Test func stopsRunFromTheMacToTheExit() {
    let stops = VerticalRoute.stops(Trunk(guardRelay: guardRelay), route)
    #expect(stops.map(\.kind) == [.mac, .guardRelay, .middle, .exit])
    #expect(stops.map(\.title) == ["Mac", "Guard", "Middle", "Exit"])
    #expect(stops.map(\.detail) == ["hidden", "Germany", "Blåbär", "185.220.101.4"])
    #expect(stops[2].flag == "🇫🇷")
}

@Test func aBridgeIsAStop() {
    let stops = VerticalRoute.stops(Trunk(bridge: .snowflake, guardRelay: guardRelay), route)
    #expect(stops.map(\.kind) == [.mac, .bridge, .guardRelay, .middle, .exit])
    #expect(stops[1].detail == "Snowflake")
}
