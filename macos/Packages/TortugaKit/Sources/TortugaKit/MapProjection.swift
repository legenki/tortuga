import CoreGraphics

/// Space kept clear around the map's routes, in points.
public struct MapInsets: Sendable, Equatable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static func uniform(_ value: CGFloat) -> MapInsets {
        MapInsets(top: value, leading: value, bottom: value, trailing: value)
    }
}

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
        // Padding takes at most half the view.
        let padding = max(0, min(padding, size.width / 2, size.height / 2))
        self.init(camera: camera, in: size, insets: .uniform(padding))
    }

    /// The same, inside the rectangle the insets leave (the routes avoid a
    /// panel over the map). A tiny floor keeps the scale finite.
    public init(camera: MapCamera, in size: CGSize, insets: MapInsets) {
        let width = max(Double(size.width - insets.leading - insets.trailing), 0.001)
        let height = max(Double(size.height - insets.top - insets.bottom), 0.001)
        // Widen to the view's shape around the centre.
        let latSpan = max(camera.latSpan, camera.lonSpan * height / width)
        let lonSpan = max(camera.lonSpan, latSpan * width / height)
        scale = min(width / lonSpan, height / latSpan)
        originLon = camera.centerLon - lonSpan / 2
        originLat = camera.centerLat + latSpan / 2
        offset = CGPoint(x: insets.leading + (width - lonSpan * scale) / 2,
                         y: insets.top + (height - latSpan * scale) / 2)
    }

    public func point(_ c: Coordinate) -> CGPoint {
        CGPoint(x: offset.x + (c.lon - originLon) * scale, y: offset.y + (originLat - c.lat) * scale)
    }

    public func coordinate(at p: CGPoint) -> Coordinate {
        Coordinate(lon: originLon + (p.x - offset.x) / scale, lat: originLat - (p.y - offset.y) / scale)
    }

    /// How big a land dot is drawn: about a third of a degree, but at least
    /// 0.85 points (the whole world) and at most 3.2 (close in).
    public var dotRadius: Double { min(max(0.3 * scale, 0.85), 3.2) }
}
