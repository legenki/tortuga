import Foundation
import Testing
@testable import TortugaKit

private let map = WorldMap(dots: [], countries: [
    "DE": Coordinate(lon: 10, lat: 51), "FR": Coordinate(lon: 2, lat: 46), "SE": Coordinate(lon: 15, lat: 62),
    "NL": Coordinate(lon: 5, lat: 52), "AT": Coordinate(lon: 14, lat: 47),
])

private func relay(_ country: String) -> Relay { Relay(nickname: "r", country: country, address: "192.0.2.1") }

private func state(apps: [AppRoute], guardCountry: String? = "DE", exceptions: [AppID] = []) -> EngineState {
    var s = EngineState()
    s.mode = .tor
    s.status = .on
    s.trunk = Trunk(bridge: nil, guardRelay: guardCountry.map(relay))
    s.apps = apps
    s.exceptions = exceptions
    return s
}

private func app(_ id: String, _ middle: String, _ exit: String) -> AppRoute {
    AppRoute(app: AppID(id), middle: relay(middle), exit: relay(exit), connections: 1, lastActive: .now)
}

@Test func theTrunkRunsFromTheMacToTheGuard() {
    let r = MapRoute(state: state(apps: []), region: "AT", map: map)
    #expect(r.mac == map.place(country: "AT"))
    #expect(r.guardPlace == map.place(country: "DE"))
}

@Test func eachAppGoesGuardMiddleExit() throws {
    let r = MapRoute(state: state(apps: [app("a", "FR", "SE")]), region: "AT", map: map)
    let tail = try #require(r.tails.first)
    #expect(tail.points == [map.place(country: "DE")!, map.place(country: "FR")!, map.place(country: "SE")!])
    #expect(tail.colorIndex == AppColor.index(for: "a"))
}

@Test func unknownCountriesAreSkipped() throws {
    let r = MapRoute(state: state(apps: [app("a", "XX", "SE")]), region: nil, map: map)
    #expect(r.mac == nil)
    let tail = try #require(r.tails.first)
    #expect(tail.points == [map.place(country: "DE")!, map.place(country: "SE")!])
    #expect(tail.exit == map.place(country: "SE"))
}

@Test func withoutAGuardTailsStartAtTheMac() throws {
    let r = MapRoute(state: state(apps: [app("a", "FR", "SE")], guardCountry: nil), region: "AT", map: map)
    #expect(r.guardPlace == nil)
    #expect(try #require(r.tails.first).points.first == map.place(country: "AT"))
}

@Test func exceptedAppsAreLeftOut() {
    let s = state(apps: [app("a", "FR", "SE"), app("b", "NL", "SE")], exceptions: [AppID("b")])
    #expect(MapRoute(state: s, region: "AT", map: map).tails.map(\.id) == ["a"])
}

@Test func appsSharingAnExitGetSlots() {
    let s = state(apps: [app("b", "NL", "SE"), app("a", "FR", "SE"), app("c", "FR", "AT")])
    let r = MapRoute(state: s, region: "AT", map: map)
    let slots = Dictionary(uniqueKeysWithValues: r.tails.map { ($0.id, $0.exitSlot) })
    #expect(slots == ["a": 0, "b": 1, "c": 0])
}

@Test func everyPlaceIsListedForFitting() {
    let r = MapRoute(state: state(apps: [app("a", "FR", "SE")]), region: "AT", map: map)
    #expect(Set(r.places) == Set(["AT", "DE", "FR", "SE"].compactMap(map.place(country:))))
}
