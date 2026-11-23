import AppKit
import SwiftUI
import TortugaKit

/// The world as dots, with this Mac's trunk and each app's route drawn on it.
/// `highlighted`: the app drawn at full strength (the others fade); nil: all.
struct RouteMap: View {
    let state: EngineState
    var highlighted: String?
    var region: String? = Locale.current.region?.identifier
    var onSelect: (String) -> Void = { _ in }
    @State private var land = LandCache()

    private var route: MapRoute { MapRoute(state: state, region: region) }
    private var lit: Bool { state.status == .on }

    var body: some View {
        let route = route
        GeometryReader { geo in
            let projection = MapProjection(fitting: route.places, in: geo.size, padding: 24)
            let landPath = land.path(for: projection)
            ZStack {
                Canvas { context, _ in draw(route, projection, land: landPath, in: &context) }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RouteSummary.text(for: state, name: AppInfo.name))
        .accessibilityIdentifier("route.map")
    }

    private func draw(_ route: MapRoute, _ projection: MapProjection, land: Path, in context: inout GraphicsContext) {
        context.fill(land, with: .color(.secondary.opacity(0.28)))
        guard state.mode == .tor else { return }

        if let mac = route.mac, let guardPlace = route.guardPlace {
            let color: Color = !lit ? .secondary.opacity(0.5) : route.bridge == nil ? .route : .bridge
            let style = route.bridge == .snowflake
                ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 5])
                : StrokeStyle(lineWidth: 3, lineCap: .round)
            context.stroke(curve(projection.point(mac), projection.point(guardPlace)), with: .color(color), style: style)
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
            if let middle { ring(middle, color, 3, in: &context) }
            if let exit {
                context.fill(Path(ellipseIn: CGRect(x: exit.x - 4, y: exit.y - 4, width: 8, height: 8)), with: .color(color))
            }
        }

        if let mac = route.mac { ring(projection.point(mac), .primary, 4, in: &context) }
        if let guardPlace = route.guardPlace { ring(projection.point(guardPlace), lit ? .route : .secondary, 4, in: &context) }
    }

    /// A gentle arc from a to b: the control point is pushed sideways by a
    /// twelfth of the distance, so the arc bulges a twenty-fourth (about 23
    /// points on a full-width line, inside the 24-point padding).
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

/// The land dots as one path, kept for the last projection: hover redraws
/// the map without rebuilding thousands of ellipses.
@MainActor private final class LandCache {
    private var projection: MapProjection?
    private var path = Path()

    func path(for projection: MapProjection) -> Path {
        if projection != self.projection {
            var land = Path()
            for dot in WorldMap.shared.dots {
                let p = projection.point(dot)
                land.addEllipse(in: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
            }
            path = land
            self.projection = projection
        }
        return path
    }
}

private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
