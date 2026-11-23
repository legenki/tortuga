import Foundation
import Testing
@testable import TortugaUI
import TortugaKit

@Test func theSummaryNamesEachAppsCountries() {
    var s = EngineState()
    s.trunk = Trunk(guardRelay: Relay(nickname: "g", country: "DE", address: "192.0.2.1"))
    s.apps = [AppRoute(app: AppID("com.apple.Safari", name: "Safari"),
                       middle: Relay(nickname: "m", country: "FR", address: "192.0.2.2"),
                       exit: Relay(nickname: "e", country: "SE", address: "192.0.2.3"),
                       connections: 2, lastActive: .now)]
    #expect(RouteSummary.text(for: s, name: { $0.name ?? $0.id }) == "Safari: Germany, France, Sweden")
}

@Test func noAppsSayWhatTheMapShows() {
    #expect(RouteSummary.text(for: EngineState(), name: { $0.id }) == "World map: no routes yet")
}
