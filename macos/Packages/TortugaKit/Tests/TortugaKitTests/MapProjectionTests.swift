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
    let left = p.coordinate(at: CGPoint(x: 0, y: 120)).lon
    let right = p.coordinate(at: CGPoint(x: 600, y: 120)).lon
    #expect(right - left >= 40)
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
}

@Test func pointAndCoordinateRoundTrip() {
    let p = MapProjection(fitting: [Coordinate(lon: -10, lat: 35), Coordinate(lon: 30, lat: 65)], in: size, padding: 16)
    let c = Coordinate(lon: 12.5, lat: 48.25)
    let back = p.coordinate(at: p.point(c))
    #expect(abs(back.lon - c.lon) < 1e-9 && abs(back.lat - c.lat) < 1e-9)
}
