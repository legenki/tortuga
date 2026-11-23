import Foundation

/// A point on Earth in degrees.
public struct Coordinate: Sendable, Hashable, Codable {
    public var lon: Double
    public var lat: Double

    public init(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

/// The land as dots and where each country is, from the bundled
/// WorldMap.json (Natural Earth; see macos/tools/map-data).
public struct WorldMap: Sendable {
    public let dots: [Coordinate]
    private let countries: [String: Coordinate]

    public static let empty = WorldMap(dots: [], countries: [:])
    public static let shared = load(from: Bundle.module.url(forResource: "WorldMap", withExtension: "json"))

    init(dots: [Coordinate], countries: [String: Coordinate]) {
        self.dots = dots
        self.countries = countries
    }

    /// Where a country is drawn: its label point. nil for an unknown code.
    public func place(country code: String) -> Coordinate? {
        countries[code.uppercased()]
    }

    /// The map in `url`, or an empty one if it is missing or unreadable: the
    /// routes are still drawn, just without land.
    static func load(from url: URL?) -> WorldMap {
        struct File: Decodable {
            var dots: [[Double]]
            var countries: [String: [Double]]
        }
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return .empty }
        let point = { (p: [Double]) in p.count == 2 ? Coordinate(lon: p[0], lat: p[1]) : nil }
        return WorldMap(dots: file.dots.compactMap(point), countries: file.countries.compactMapValues(point))
    }
}
