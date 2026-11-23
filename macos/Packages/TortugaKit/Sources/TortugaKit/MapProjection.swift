import CoreGraphics

/// Equirectangular projection fitted to a set of places: degrees of longitude
/// and latitude are the same length, the places fill the view inside the
/// padding, and at least `minSpan` degrees of longitude show.
public struct MapProjection: Sendable, Equatable {
    /// The whole map: Natural Earth land without Antarctica (see map-data).
    public static let world = (lon: -180.0...180.0, lat: -58.0...84.0)

    let scale: Double
    let originLon: Double
    let originLat: Double
    let offset: CGPoint

    public init(fitting places: [Coordinate], in size: CGSize, padding: CGFloat, minSpan: Double = 40) {
        var lon = Self.world.lon
        var lat = Self.world.lat
        if let first = places.first {
            lon = places.reduce(first.lon...first.lon) { min($0.lowerBound, $1.lon)...max($0.upperBound, $1.lon) }
            lat = places.reduce(first.lat...first.lat) { min($0.lowerBound, $1.lat)...max($0.upperBound, $1.lat) }
        }
        // Padding takes at most half the view; a tiny floor keeps the scale
        // finite for an empty view.
        let padding = max(0, min(padding, size.width / 2, size.height / 2))
        let width = max(Double(size.width - 2 * padding), 0.001)
        let height = max(Double(size.height - 2 * padding), 0.001)
        // Widen to the minimum span, and to the view's shape, around the centre.
        let lonSpan = max(lon.upperBound - lon.lowerBound, places.isEmpty ? 0 : minSpan)
        let latSpan = max(lat.upperBound - lat.lowerBound, lonSpan * height / width)
        let lonSpanFitted = max(lonSpan, latSpan * width / height)
        let midLon = (lon.lowerBound + lon.upperBound) / 2
        let midLat = (lat.lowerBound + lat.upperBound) / 2
        scale = min(width / lonSpanFitted, height / latSpan)
        originLon = midLon - lonSpanFitted / 2
        originLat = midLat + latSpan / 2
        offset = CGPoint(x: padding + (width - lonSpanFitted * scale) / 2,
                         y: padding + (height - latSpan * scale) / 2)
    }

    public func point(_ c: Coordinate) -> CGPoint {
        CGPoint(x: offset.x + (c.lon - originLon) * scale, y: offset.y + (originLat - c.lat) * scale)
    }

    public func coordinate(at p: CGPoint) -> Coordinate {
        Coordinate(lon: originLon + (p.x - offset.x) / scale, lat: originLat - (p.y - offset.y) / scale)
    }
}
