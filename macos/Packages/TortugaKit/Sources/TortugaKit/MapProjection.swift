import CoreGraphics

/// Equirectangular projection fitted to a camera (or a set of places):
/// degrees of longitude and latitude are the same length, and the camera's
/// spans fill the view inside the padding.
public struct MapProjection: Sendable, Equatable {
    /// The whole map: Natural Earth land without Antarctica (see map-data).
    public static let world = (lon: -180.0...180.0, lat: -58.0...84.0)

    let scale: Double
    let originLon: Double
    let originLat: Double
    let offset: CGPoint

    public init(fitting places: [Coordinate], in size: CGSize, padding: CGFloat, minSpan: Double = 40) {
        self.init(camera: MapCamera(fitting: places, minSpan: minSpan), in: size, padding: padding)
    }

    /// Shows at least the camera's spans around its centre, widened to the
    /// view's shape.
    public init(camera: MapCamera, in size: CGSize, padding: CGFloat) {
        // Padding takes at most half the view; a tiny floor keeps the scale
        // finite for an empty view.
        let padding = max(0, min(padding, size.width / 2, size.height / 2))
        let width = max(Double(size.width - 2 * padding), 0.001)
        let height = max(Double(size.height - 2 * padding), 0.001)
        // Widen to the view's shape around the centre.
        let latSpan = max(camera.latSpan, camera.lonSpan * height / width)
        let lonSpan = max(camera.lonSpan, latSpan * width / height)
        scale = min(width / lonSpan, height / latSpan)
        originLon = camera.centerLon - lonSpan / 2
        originLat = camera.centerLat + latSpan / 2
        offset = CGPoint(x: padding + (width - lonSpan * scale) / 2,
                         y: padding + (height - latSpan * scale) / 2)
    }

    public func point(_ c: Coordinate) -> CGPoint {
        CGPoint(x: offset.x + (c.lon - originLon) * scale, y: offset.y + (originLat - c.lat) * scale)
    }

    public func coordinate(at p: CGPoint) -> Coordinate {
        Coordinate(lon: originLon + (p.x - offset.x) / scale, lat: originLat - (p.y - offset.y) / scale)
    }
}
