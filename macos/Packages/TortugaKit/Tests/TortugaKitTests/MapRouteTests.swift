import Foundation
import Testing
@testable import TortugaKit

private let map = WorldMap(dots: [], countries: [
    "DE": Coordinate(lon: 10, lat: 51), "FR": Coordinate(lon: 2, lat: 46), "SE": Coordinate(lon: 15, lat: 62),
    "NL": Coordinate(lon: 5, lat: 52), "AT": Coordinate(lon: 14, lat: 47),
])

private func relay(_ country: String) -> Relay { Relay(nickname: "r", country: country, address: "192.0.2.1") }

private func state(apps: [AppRoute], guardCountry: String? = "DE", exceptions: [AppID] = [],
                   mode: Mode = .tor, bridge: BridgeKind? = nil) -> EngineState {
    var s = EngineState()
    s.mode = mode
    s.status = .on
    s.trunk = Trunk(bridge: bridge, guardRelay: guardCountry.map(relay))
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
    #expect(tail.middle == nil)
    #expect(tail.exit == map.place(country: "SE"))
}

@Test func anUnknownExitLeavesTheMiddle() throws {
    // The real engine sends "??" for a country it doesn't know.
    let r = MapRoute(state: state(apps: [app("a", "FR", "??")]), region: "AT", map: map)
    let tail = try #require(r.tails.first)
    #expect(tail.start == map.place(country: "DE"))
    #expect(tail.middle == map.place(country: "FR"))
    #expect(tail.exit == nil)
    #expect(tail.points == [map.place(country: "DE")!, map.place(country: "FR")!])
}

@Test func aGuardInAnUnknownCountryStartsTailsAtTheMac() throws {
    let r = MapRoute(state: state(apps: [app("a", "FR", "SE")], guardCountry: "??"), region: "AT", map: map)
    #expect(r.guardPlace == nil)
    #expect(try #require(r.tails.first).start == map.place(country: "AT"))
}

@Test func theBridgeIsPassedThrough() {
    #expect(MapRoute(state: state(apps: [], bridge: .snowflake), region: "AT", map: map).bridge == .snowflake)
    #expect(MapRoute(state: state(apps: []), region: "AT", map: map).bridge == nil)
}

@Test func directModeShowsJustTheWorld() {
    let s = state(apps: [app("a", "FR", "SE")], mode: .direct)
    let r = MapRoute(state: s, region: "AT", map: map)
    #expect(r.mac == nil)
    #expect(r.guardPlace == nil)
    #expect(r.tails.isEmpty)
    #expect(r.places.isEmpty)
}

@Test func withNothingRoutedYetTheWholeWorldShows() {
    let r = MapRoute(state: state(apps: [], guardCountry: nil), region: "AT", map: map)
    #expect(r.mac == map.place(country: "AT"))
    #expect(r.places.isEmpty)
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
    // AT is the Mac's country, so its first slot is 1, not 0 (on the Mac's ring).
    let s = state(apps: [app("b", "NL", "SE"), app("a", "FR", "SE"), app("c", "FR", "AT")])
    let r = MapRoute(state: s, region: "AT", map: map)
    let slots = Dictionary(uniqueKeysWithValues: r.tails.map { ($0.id, $0.exitSlot) })
    #expect(slots == ["a": 0, "b": 1, "c": 1])
}

@Test func middlesSharingACountryGetSlots() {
    let s = state(apps: [app("b", "FR", "SE"), app("a", "FR", "NL"), app("c", "SE", "FR")])
    let r = MapRoute(state: s, region: "AT", map: map)
    let middles = Dictionary(uniqueKeysWithValues: r.tails.map { ($0.id, $0.middleSlot) })
    let exits = Dictionary(uniqueKeysWithValues: r.tails.map { ($0.id, $0.exitSlot) })
    // One counter per country for both roles, in app order, middle before exit:
    // a: FR 0, NL 0; b: FR 1, SE 0; c: SE 1, FR 2.
    #expect(middles == ["a": 0, "b": 1, "c": 1])
    #expect(exits == ["a": 0, "b": 0, "c": 2])
}

@Test func noSlotZeroOnTheGuardOrTheMac() {
    let s = state(apps: [app("a", "DE", "AT")])
    let tail = MapRoute(state: s, region: "AT", map: map).tails[0]
    #expect(tail.middleSlot == 1)
    #expect(tail.exitSlot == 1)
}

@Test func everyPlaceIsListedForFitting() {
    let r = MapRoute(state: state(apps: [app("a", "FR", "SE")]), region: "AT", map: map)
    #expect(Set(r.places) == Set(["AT", "DE", "FR", "SE"].compactMap(map.place(country:))))
}

@Test func focusPlacesAreTheAppsRouteAndTheMac() {
    let s = state(apps: [app("a", "FR", "SE"), app("b", "NL", "NL")])
    let r = MapRoute(state: s, region: "AT", map: map)
    #expect(r.focusPlaces(for: "a") == ["AT", "DE", "FR", "SE"].compactMap(map.place(country:)))
    #expect(!r.focusPlaces(for: "a").contains(map.place(country: "NL")!))
}

@Test func focusPlacesWithoutAGuardStartAtTheMac() {
    let r = MapRoute(state: state(apps: [app("a", "FR", "SE")], guardCountry: nil), region: "AT", map: map)
    #expect(Set(r.focusPlaces(for: "a")) == Set(["AT", "FR", "SE"].compactMap(map.place(country:))))
}

@Test func focusPlacesAreEmptyForAnAppWithoutARoute() {
    let s = state(apps: [app("a", "FR", "SE"), app("b", "NL", "SE"), app("c", "XX", "??")], exceptions: [AppID("b")])
    let r = MapRoute(state: s, region: "AT", map: map)
    #expect(r.focusPlaces(for: "nope").isEmpty)
    #expect(r.focusPlaces(for: "b").isEmpty)  // excepted
    #expect(r.focusPlaces(for: "c").isEmpty)  // no known middle or exit
    #expect(MapRoute(state: state(apps: [app("a", "FR", "SE")], mode: .direct), region: "AT", map: map)
        .focusPlaces(for: "a").isEmpty)
}
