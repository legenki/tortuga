import CoreGraphics
import Testing
@testable import TortugaKit

@Test func noPlacesIsTheWholeWorld() {
    let c = MapCamera(fitting: [])
    #expect(c == MapCamera(centerLon: 0, centerLat: 13, lonSpan: 360, latSpan: 142))
}

@Test func onePlaceGetsTheMinimumSpan() {
    let c = MapCamera(fitting: [Coordinate(lon: 10, lat: 51)], minSpan: 25)
    #expect(c == MapCamera(centerLon: 10, centerLat: 51, lonSpan: 25, latSpan: 0))
}

@Test func theCameraIsTheBoundingBox() {
    let c = MapCamera(fitting: [Coordinate(lon: -77, lat: 39), Coordinate(lon: 18, lat: 59), Coordinate(lon: 8.5, lat: 47)])
    #expect(c == MapCamera(centerLon: -29.5, centerLat: 49, lonSpan: 95, latSpan: 20))
}

@Test func fittingPlacesIsFittingTheirCamera() {
    let cases: [([Coordinate], CGSize, CGFloat, Double)] = [
        ([], CGSize(width: 600, height: 240), 24, 40),
        ([Coordinate(lon: 10, lat: 51)], CGSize(width: 600, height: 240), 24, 25),
        ([Coordinate(lon: 8, lat: 50), Coordinate(lon: 11, lat: 51)], CGSize(width: 200, height: 800), 20, 40),
        ([Coordinate(lon: -77, lat: 39), Coordinate(lon: 18, lat: 59)], CGSize(width: 600, height: 240), 1000, 40),
        ([Coordinate(lon: -120, lat: -40), Coordinate(lon: 150, lat: 70)], .zero, 24, 40),
    ]
    for (places, size, padding, minSpan) in cases {
        let fitted = MapProjection(fitting: places, in: size, padding: padding, minSpan: minSpan)
        let viaCamera = MapProjection(camera: MapCamera(fitting: places, minSpan: minSpan), in: size, padding: padding)
        #expect(fitted == viaCamera, "\(places) in \(size)")
    }
}

@Test func aCameraIsCentredInTheView() {
    let size = CGSize(width: 600, height: 240)
    let p = MapProjection(camera: MapCamera(centerLon: 10, centerLat: 50, lonSpan: 30, latSpan: 5), in: size, padding: 20)
    let centre = p.point(Coordinate(lon: 10, lat: 50))
    #expect(abs(centre.x - 300) < 0.001 && abs(centre.y - 120) < 0.001)
    // 30° across the 560 points inside the padding.
    let left = p.coordinate(at: CGPoint(x: 20, y: 120)).lon
    let right = p.coordinate(at: CGPoint(x: 580, y: 120)).lon
    #expect(abs(right - left - 30) < 0.001)
}
