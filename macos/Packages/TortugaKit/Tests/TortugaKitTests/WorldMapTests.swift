import Foundation
import Testing
@testable import TortugaKit

@Test func theBundledMapLoads() {
    let map = WorldMap.shared
    #expect(map.dots.count > 1000)
    #expect(map.place(country: "DE") != nil)
}

@Test func placesAreFoundInAnyCase() throws {
    let de = try #require(WorldMap.shared.place(country: "de"))
    #expect(WorldMap.shared.place(country: "DE") == de)
    #expect((5...16).contains(de.lon) && (47...56).contains(de.lat))
}

@Test func smallCountriesWithExitsArePresent() {
    for code in ["LU", "MC", "SG", "IS", "CH", "NL", "SE", "US", "FR"] {
        #expect(WorldMap.shared.place(country: code) != nil, "\(code)")
    }
}

@Test func unknownCountriesAreNil() {
    #expect(WorldMap.shared.place(country: "XX") == nil)
    #expect(WorldMap.shared.place(country: "") == nil)
}

@Test func aMissingFileGivesAnEmptyMap() {
    let map = WorldMap.load(from: URL(fileURLWithPath: "/nonexistent/WorldMap.json"))
    #expect(map.dots.isEmpty)
    #expect(map.place(country: "DE") == nil)
}

@Test func franceIsPlacedInEurope() throws {
    // Its label point, not pulled toward French Guiana.
    let fr = try #require(WorldMap.shared.place(country: "FR"))
    #expect((0...8).contains(fr.lon) && (42...50).contains(fr.lat))
}

@Test func theDotsAreOnLand() {
    func near(_ lon: Double, _ lat: Double, within degrees: Double) -> Bool {
        WorldMap.shared.dots.contains { hypot($0.lon - lon, $0.lat - lat) <= degrees }
    }
    #expect(near(10, 51, within: 1.5), "Germany")
    #expect(near(-100, 40, within: 1.5), "the United States")
    #expect(!near(-30, 30, within: 1), "the Atlantic")
}

@Test func everyDemoCountryHasAPlace() {
    for code in DemoData.countries {
        #expect(WorldMap.shared.place(country: code) != nil, "\(code)")
    }
}

@Test func malformedJSONGivesAnEmptyMap() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorldMap-\(UUID().uuidString).json")
    try Data(#"{"dots": [[1, 2]], "countries": "#.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let map = WorldMap.load(from: url)
    #expect(map.dots.isEmpty)
    #expect(map.place(country: "DE") == nil)
}

@Test func antarcticaIsLeftOut() {
    // Its label point is south of the map (MapProjection.world).
    #expect(WorldMap.shared.place(country: "AQ") == nil)
}
