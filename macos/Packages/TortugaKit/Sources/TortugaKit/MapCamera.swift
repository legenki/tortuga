/// What part of the world the map shows, before it is fitted to a view: a
/// centre and how many degrees of longitude and latitude must be visible.
/// MapProjection widens it to the view's shape. A plain value, so the UI can
/// animate from one camera to another.
public struct MapCamera: Sendable, Equatable {
    public var centerLon: Double
    public var centerLat: Double
    public var lonSpan: Double
    public var latSpan: Double

    public init(centerLon: Double, centerLat: Double, lonSpan: Double, latSpan: Double) {
        self.centerLon = centerLon
        self.centerLat = centerLat
        self.lonSpan = lonSpan
        self.latSpan = latSpan
    }

    /// The bounding box of the places, at least `minSpan` degrees of longitude
    /// wide. No places: the whole world.
    public init(fitting places: [Coordinate], minSpan: Double = 40) {
        var lon = MapProjection.world.lon
        var lat = MapProjection.world.lat
        if let first = places.first {
            lon = places.reduce(first.lon...first.lon) { min($0.lowerBound, $1.lon)...max($0.upperBound, $1.lon) }
            lat = places.reduce(first.lat...first.lat) { min($0.lowerBound, $1.lat)...max($0.upperBound, $1.lat) }
        }
        self.init(centerLon: (lon.lowerBound + lon.upperBound) / 2,
                  centerLat: (lat.lowerBound + lat.upperBound) / 2,
                  lonSpan: max(lon.upperBound - lon.lowerBound, places.isEmpty ? 0 : minSpan),
                  latSpan: lat.upperBound - lat.lowerBound)
    }
}
