import Foundation
import Testing
import TortugaKit
@testable import TortugaUI

private let de = Relay(nickname: "g", country: "DE", address: "1.1.1.1")
private let nl = Relay(nickname: "m", country: "NL", address: "2.2.2.2")
private let se = Relay(nickname: "e", country: "SE", address: "3.3.3.3")

@Test func trunkWithBridgeAndGuard() {
    let stops = MetroLine.Stop.trunk(Trunk(bridge: .snowflake, guardRelay: de))
    #expect(stops.map(\.id) == ["you", "bridge", "guard"])
    #expect(stops[1].kind == .bridge(.snowflake))
    #expect(stops[2].flag == "🇩🇪")
}

@Test func trunkWithoutTor() {
    #expect(MetroLine.Stop.trunk(Trunk()).map(\.id) == ["you"])
}

@Test func fullRouteEndsAtTheExit() {
    let route = AppRoute(app: AppID("a"), middle: nl, exit: se, connections: 1, lastActive: .now)
    let stops = MetroLine.Stop.full(Trunk(guardRelay: de), route)
    #expect(stops.map(\.id) == ["you", "guard", "middle", "exit"])
    #expect(stops.last?.kind == .exit)
    #expect(MetroLine.Stop.tail(route).map(\.id) == ["middle", "exit"])
}
