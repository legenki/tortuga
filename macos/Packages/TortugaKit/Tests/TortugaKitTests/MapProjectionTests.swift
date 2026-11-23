import CoreGraphics
import Testing
@testable import TortugaKit

private let size = CGSize(width: 600, height: 240)

@Test func fitsThePointsInsideThePadding() {
    let points = [Coordinate(lon: -77, lat: 39), Coordinate(lon: 18, lat: 59), Coordinate(lon: 8.5, lat: 47)]
    let p = MapProjection(fitting: points, in: size, padding: 20)
    for c in points {
        let xy = p.point(c)
        #expect((19.999...580.001).contains(xy.x), "\(c)")
        #expect((19.999...220.001).contains(xy.y), "\(c)")
    }
}

@Test func northIsUpAndEastIsRight() {
    let p = MapProjection(fitting: [Coordinate(lon: 0, lat: 40), Coordinate(lon: 30, lat: 60)], in: size, padding: 20)
    #expect(p.point(Coordinate(lon: 0, lat: 60)).y < p.point(Coordinate(lon: 0, lat: 40)).y)
    #expect(p.point(Coordinate(lon: 30, lat: 50)).x > p.point(Coordinate(lon: 0, lat: 50)).x)
}

@Test func aSmallRouteIsNotBlownUp() {
    // Two places 3° apart still get at least 40° of longitude across the view.
    let p = MapProjection(fitting: [Coordinate(lon: 8, lat: 50), Coordinate(lon: 11, lat: 51)], in: size, padding: 20)
    let left = p.coordinate(at: CGPoint(x: 20, y: 120)).lon
    let right = p.coordinate(at: CGPoint(x: 580, y: 120)).lon
    #expect(right - left >= 40 - 0.001)
}

@Test func aSmallRouteInATallNarrowViewKeepsTheMinimumSpan() {
    let tall = CGSize(width: 200, height: 800)
    let p = MapProjection(fitting: [Coordinate(lon: 8, lat: 50), Coordinate(lon: 11, lat: 51)], in: tall, padding: 20)
    let left = p.coordinate(at: CGPoint(x: 20, y: 400)).lon
    let right = p.coordinate(at: CGPoint(x: 180, y: 400)).lon
    #expect(right - left >= 40 - 0.001)
}

@Test func noPointsShowTheWholeWorld() {
    let p = MapProjection(fitting: [], in: size, padding: 0)
    let left = p.coordinate(at: CGPoint(x: 0, y: 120)).lon
    let right = p.coordinate(at: CGPoint(x: 600, y: 120)).lon
    #expect(left <= -179 && right >= 179)
    let top = p.coordinate(at: CGPoint(x: 300, y: 0)).lat
    let bottom = p.coordinate(at: CGPoint(x: 300, y: 240)).lat
    #expect(top >= 84 - 0.001 && bottom <= -58 + 0.001)
}

@Test func thePlacesAreCentred() {
    let points = [Coordinate(lon: -77, lat: 39), Coordinate(lon: 18, lat: 59), Coordinate(lon: 8.5, lat: 47)]
    let p = MapProjection(fitting: points, in: size, padding: 20)
    let centre = p.point(Coordinate(lon: (-77 + 18) / 2, lat: (39 + 59) / 2))
    #expect(abs(centre.x - 300) < 0.001 && abs(centre.y - 120) < 0.001)
}

private let points = [Coordinate(lon: -77, lat: 39), Coordinate(lon: 18, lat: 59)]

private func expectInside(_ p: MapProjection, _ view: CGSize) {
    for c in points {
        let xy = p.point(c)
        #expect(xy.x.isFinite && xy.y.isFinite, "\(c)")
        #expect((-0.01...view.width + 0.01).contains(xy.x), "\(c): \(xy)")
        #expect((-0.01...view.height + 0.01).contains(xy.y), "\(c): \(xy)")
    }
    let back = p.coordinate(at: CGPoint(x: view.width / 2, y: view.height / 2))
    #expect(back.lon.isFinite && back.lat.isFinite)
}

@Test func aZeroSizeViewGivesNoNaN() {
    expectInside(MapProjection(fitting: points, in: .zero, padding: 24), .zero)
    expectInside(MapProjection(fitting: [], in: .zero, padding: 0), .zero)
}

@Test func paddingLargerThanTheViewIsClamped() {
    expectInside(MapProjection(fitting: points, in: size, padding: 1000), size)
    expectInside(MapProjection(fitting: [], in: CGSize(width: 40, height: 30), padding: 24), CGSize(width: 40, height: 30))
}

@Test func pointAndCoordinateRoundTrip() {
    let p = MapProjection(fitting: [Coordinate(lon: -10, lat: 35), Coordinate(lon: 30, lat: 65)], in: size, padding: 16)
    let c = Coordinate(lon: 12.5, lat: 48.25)
    let back = p.coordinate(at: p.point(c))
    #expect(abs(back.lon - c.lon) < 1e-9 && abs(back.lat - c.lat) < 1e-9)
}

@Test func dotsGrowWithTheZoomWithinLimits() {
    let world = MapProjection(camera: MapCamera(centerLon: 0, centerLat: 13, lonSpan: 360, latSpan: 142),
                              in: CGSize(width: 600, height: 240), padding: 0)
    #expect(world.dotRadius == 0.85)
    let close = MapProjection(camera: MapCamera(centerLon: 10, centerLat: 50, lonSpan: 20, latSpan: 8),
                              in: CGSize(width: 600, height: 240), padding: 0)
    #expect(close.dotRadius == 3.2)
    let middle = MapProjection(camera: MapCamera(centerLon: 10, centerLat: 50, lonSpan: 100, latSpan: 10),
                               in: CGSize(width: 600, height: 240), padding: 0)
    #expect(abs(middle.dotRadius - 1.8) < 1e-9)
}

@Test func insetsMoveTheCentreIntoTheFreeSpace() {
    let camera = MapCamera(centerLon: 10, centerLat: 50, lonSpan: 40, latSpan: 20)
    let p = MapProjection(camera: camera, in: CGSize(width: 900, height: 600),
                          insets: MapInsets(top: 60, leading: 300, bottom: 20, trailing: 20))
    let centre = p.point(Coordinate(lon: 10, lat: 50))
    #expect(abs(centre.x - (300 + (900 - 320) / 2)) < 1e-9)
    #expect(abs(centre.y - (60 + (600 - 80) / 2)) < 1e-9)
}

@Test func uniformInsetsMatchPadding() {
    let camera = MapCamera(centerLon: 0, centerLat: 0, lonSpan: 60, latSpan: 30)
    let size = CGSize(width: 600, height: 240)
    #expect(MapProjection(camera: camera, in: size, insets: .uniform(24))
            == MapProjection(camera: camera, in: size, padding: 24))
}
