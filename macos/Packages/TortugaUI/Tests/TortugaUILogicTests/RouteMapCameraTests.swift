import Foundation
import Testing
@testable import TortugaUI
import TortugaKit

private func relay(_ country: String) -> Relay { Relay(nickname: "r", country: country, address: "192.0.2.1") }

private let route: MapRoute = {
    var s = EngineState()
    s.mode = .tor
    s.status = .on
    s.trunk = Trunk(guardRelay: relay("DE"))
    s.apps = [AppRoute(app: AppID("a"), middle: relay("FR"), exit: relay("SE"), connections: 1, lastActive: .now),
              AppRoute(app: AppID("b"), middle: relay("NL"), exit: relay("JP"), connections: 1, lastActive: .now)]
    return MapRoute(state: s, region: "AT")
}()

@Test func nothingFocusedShowsEverything() {
    #expect(RouteMap.camera(for: route, focused: nil) == MapCamera(fitting: route.places))
}

@Test func aFocusedAppFramesItsRoute() {
    #expect(RouteMap.camera(for: route, focused: "a") == MapCamera(fitting: route.focusPlaces(for: "a"), minSpan: 25))
    #expect(RouteMap.camera(for: route, focused: "a") != RouteMap.camera(for: route, focused: nil))
}

@Test func anAppNotOnTheMapKeepsTheOverview() {
    #expect(RouteMap.camera(for: route, focused: "gone") == MapCamera(fitting: route.places))
}

@Test func theCameraAnimatesThroughItsFourNumbers() {
    var c = MapCamera(centerLon: 0, centerLat: 0, lonSpan: 100, latSpan: 50)
    var data = c.animatableData
    data.scale(by: 0.5)
    c.animatableData = data
    #expect(c == MapCamera(centerLon: 0, centerLat: 0, lonSpan: 50, latSpan: 25))
}
