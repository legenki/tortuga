import AppKit
import SwiftUI
import TortugaKit

/// The world as dots, with this Mac's trunk and each app's route drawn on it.
/// `highlighted`: the app drawn at full strength (the others fade); nil: all.
/// `focused`: the app whose route the map flies to; nil, or an app with no
/// known places on the map: the overview of everything.
struct RouteMap: View {
    let state: EngineState
    var highlighted: String?
    var focused: String?
    /// Space kept clear of routes (the app panel and the toolbar cover it).
    var insets = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
    /// The Bridges card is over the map: dim land, no routes.
    var dimmed = false
    var region: String? = Locale.current.region?.identifier
    var onSelect: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var land = LandCache()

    var body: some View {
        let route = MapRoute(state: state, region: region)
        let camera = Self.camera(for: route, focused: focused)
        GeometryReader { geo in
            RouteMapLayer(state: state, route: route, highlighted: highlighted, camera: camera,
                          size: geo.size, insets: insets, dimmed: dimmed, moving: !reduceMotion,
                          land: land, onSelect: onSelect)
        }
        // Owns the camera's animation: a new camera (another app focused, or
        // the routes changed) flies there; the row's own animation is kept
        // out of the map. Reduce Motion jumps.
        .animation(reduceMotion ? nil : .smooth(duration: 1.0), value: camera)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RouteSummary.text(for: state, name: AppInfo.name))
        .accessibilityIdentifier("route.map")
    }

    /// The focused app's route if it has places on the map, else everything.
    static func camera(for route: MapRoute, focused: String?) -> MapCamera {
        if let focused {
            let places = route.focusPlaces(for: focused)
            if !places.isEmpty { return MapCamera(fitting: places, minSpan: 25) }
        }
        return MapCamera(fitting: route.places)
    }

    /// How long an active exit's pulse takes: 3.2 s with no connections,
    /// down to 1 s at twelve or more.
    static func pulsePeriod(connections: Int) -> Double {
        3.2 - Double(min(max(connections, 0), 12)) * (2.2 / 12)
    }

    /// The dash phase of the traffic flow: 12 points a second, repeating
    /// every dash (3 on, 9 off).
    static func flowPhase(at seconds: Double) -> Double {
        (seconds * 12).truncatingRemainder(dividingBy: 12)
    }
}

/// The map drawn through one camera. Animatable: SwiftUI interpolates the
/// camera between frames, and the land, routes and tap targets all follow it.
private struct RouteMapLayer: View, Animatable {
    let state: EngineState
    let route: MapRoute
    let highlighted: String?
    var camera: MapCamera
    let size: CGSize
    let insets: EdgeInsets
    let dimmed: Bool
    let moving: Bool
    let land: LandCache
    let onSelect: (String) -> Void

    nonisolated var animatableData: MapCamera.AnimatableData {
        get { camera.animatableData }
        set { camera.animatableData = newValue }
    }

    private var lit: Bool { state.status == .on }

    var body: some View {
        let projection = MapProjection(camera: camera, in: size,
                                       insets: MapInsets(top: insets.top, leading: insets.leading,
                                                         bottom: insets.bottom, trailing: insets.trailing))
        let landPath = land.path(for: projection, in: size)
        ZStack {
            // The land is its own layer: it redraws only when the projection
            // (or dimming) changes, not on every animation frame.
            LandLayer(path: landPath, dimmed: dimmed).equatable()
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving || !lit || dimmed)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, _ in draw(route, projection, time: moving ? t : nil, in: &context) }
            }
            if !dimmed {
                ForEach(route.tails) { tail in
                    if let exit = tail.exit {
                        let p = projection.point(exit) + AppColor.offset(slot: tail.exitSlot)
                        Circle().fill(.clear).contentShape(.circle).frame(width: 16, height: 16)
                            .position(p)
                            .onTapGesture { onSelect(tail.id) }
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func draw(_ route: MapRoute, _ projection: MapProjection, time: Double?, in context: inout GraphicsContext) {
        guard state.mode == .tor, !dimmed else { return }
        let flow = time.map { StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 9], dashPhase: -RouteMap.flowPhase(at: $0)) }

        if let mac = route.mac, let guardPlace = route.guardPlace {
            let color: Color = !lit ? .secondary.opacity(0.5) : route.bridge == nil ? .route : .bridge
            let style = route.bridge == .snowflake
                ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 5])
                : StrokeStyle(lineWidth: 3, lineCap: .round)
            let trunk = curve(projection.point(mac), projection.point(guardPlace))
            context.stroke(trunk, with: .color(color), style: style)
            if lit, let flow { context.stroke(trunk, with: .color(.white.opacity(0.7)), style: flow) }
        }

        for tail in route.tails {
            let faded = highlighted != nil && highlighted != tail.id
            let color = (lit ? Color.app(tail.id) : .secondary).opacity(faded ? 0.3 : 1)
            let start = tail.start.map(projection.point)
            let middle = tail.middle.map { projection.point($0) + AppColor.offset(slot: tail.middleSlot) }
            let exit = tail.exit.map { projection.point($0) + AppColor.offset(slot: tail.exitSlot) }
            let points = [start, middle, exit].compactMap { $0 }
            var path = Path()
            for (a, b) in zip(points, points.dropFirst()) { path.addPath(curve(a, b)) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: highlighted == tail.id ? 2.5 : 1.8, lineCap: .round))
            if lit, highlighted == tail.id, let flow { context.stroke(path, with: .color(.white.opacity(0.7)), style: flow) }
            if let middle { ring(middle, color, 3, in: &context) }
            if let exit {
                let appRoute = state.apps.first { $0.id == tail.id }
                if lit, !faded, let time, let appRoute, appRoute.connections > 0 {
                    let period = RouteMap.pulsePeriod(connections: appRoute.connections)
                    let f = time.truncatingRemainder(dividingBy: period) / period
                    let r = 4 + 9 * f
                    context.fill(Path(ellipseIn: CGRect(x: exit.x - r, y: exit.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(color.opacity(0.5 * (1 - f))))
                }
                context.fill(Path(ellipseIn: CGRect(x: exit.x - 4, y: exit.y - 4, width: 8, height: 8)), with: .color(color))
                if lit, highlighted == tail.id, let appRoute {
                    let label = "\(appRoute.exit.flag) \(RouteSummary.country(appRoute.exit.country))"
                    context.draw(Text(label).font(.caption.weight(.semibold)), at: CGPoint(x: exit.x + 10, y: exit.y), anchor: .leading)
                }
            }
        }

        if let mac = route.mac { ring(projection.point(mac), .primary, 4, in: &context) }
        if let guardPlace = route.guardPlace { ring(projection.point(guardPlace), lit ? .route : .secondary, 4, in: &context) }
    }

    /// A gentle arc from a to b: the control point is pushed sideways by a
    /// twelfth of the distance, so the arc bulges a twenty-fourth (about 23
    /// points on a full-width line, inside the 24-point insets).
    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let control = CGPoint(x: mid.x + (b.y - a.y) / 12, y: mid.y - (b.x - a.x) / 12)
        path.addQuadCurve(to: b, control: control)
        return path
    }

    private func ring(_ p: CGPoint, _ color: Color, _ r: CGFloat, in context: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(circle, with: .color(color), lineWidth: 2)
    }
}

/// The land dots, filled once per path.
private struct LandLayer: View, Equatable {
    let path: Path
    let dimmed: Bool

    var body: some View {
        Canvas { context, _ in
            context.fill(path, with: .color(.secondary.opacity(dimmed ? 0.14 : 0.28)))
        }
    }
}

/// The land dots as one path, kept for the last projection and size; dots
/// off screen are skipped. Hover redraws the map without rebuilding
/// thousands of ellipses. While the camera flies every frame has a new
/// projection, so the path is rebuilt each frame.
@MainActor private final class LandCache {
    private var projection: MapProjection?
    private var size: CGSize = .zero
    private var path = Path()

    func path(for projection: MapProjection, in size: CGSize) -> Path {
        if projection != self.projection || size != self.size {
            let r = projection.dotRadius
            let visible = CGRect(origin: .zero, size: size).insetBy(dx: -r, dy: -r)
            var land = Path()
            for dot in WorldMap.shared.dots {
                let p = projection.point(dot)
                guard visible.contains(p) else { continue }
                land.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
            path = land
            self.projection = projection
            self.size = size
        }
        return path
    }
}

extension MapCamera {
    typealias AnimatableData = AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>

    /// The four numbers SwiftUI interpolates: centre, then the spans as
    /// logarithms, so a flight zooms at an even rate instead of rushing at
    /// the end. A zero span is floored to keep the logarithm finite.
    var animatableData: AnimatableData {
        get {
            AnimatablePair(AnimatablePair(centerLon, centerLat),
                           AnimatablePair(log(max(lonSpan, Self.minLogSpan)), log(max(latSpan, Self.minLogSpan))))
        }
        set {
            centerLon = newValue.first.first
            centerLat = newValue.first.second
            lonSpan = exp(newValue.second.first)
            latSpan = exp(newValue.second.second)
        }
    }

    private static let minLogSpan = 0.01
}

private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
