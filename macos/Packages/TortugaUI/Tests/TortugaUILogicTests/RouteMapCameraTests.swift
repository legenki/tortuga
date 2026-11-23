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

@Test func halfwayTheZoomIsTheGeometricMean() {
    // Spans are interpolated as logarithms: halfway from 160° to 10° shows
    // 40°, not 85°, so the zoom runs at an even rate.
    let from = MapCamera(centerLon: 0, centerLat: 0, lonSpan: 160, latSpan: 80)
    let to = MapCamera(centerLon: 20, centerLat: 50, lonSpan: 10, latSpan: 5)
    var delta = to.animatableData
    delta -= from.animatableData
    delta.scale(by: 0.5)
    var halfway = from
    halfway.animatableData = from.animatableData + delta
    #expect(abs(halfway.centerLon - 10) < 1e-9 && abs(halfway.centerLat - 25) < 1e-9)
    #expect(abs(halfway.lonSpan - 40) < 1e-9 && abs(halfway.latSpan - 20) < 1e-9)
}

@Test func aZeroSpanStaysFinite() {
    var c = MapCamera(centerLon: 0, centerLat: 0, lonSpan: 40, latSpan: 0)
    c.animatableData = c.animatableData
    #expect(c.latSpan.isFinite && c.latSpan > 0)
}
