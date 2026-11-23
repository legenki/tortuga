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
