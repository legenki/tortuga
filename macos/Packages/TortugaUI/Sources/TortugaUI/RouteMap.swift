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

    private var route: MapRoute { MapRoute(state: state, region: region) }
    private var lit: Bool { state.status == .on }

    var body: some View {
        let route = route
        GeometryReader { geo in
            let projection = MapProjection(fitting: route.places, in: geo.size, padding: 18)
            ZStack {
                Canvas { context, _ in draw(route, projection, in: &context) }
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

    private func draw(_ route: MapRoute, _ projection: MapProjection, in context: inout GraphicsContext) {
        let land = Color.secondary.opacity(0.28)
        for dot in WorldMap.shared.dots {
            let p = projection.point(dot)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(land))
        }
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
            let points = tail.points.map(projection.point)
            let end = points.last.map { $0 + AppColor.offset(slot: tail.exitSlot) }
            var path = Path()
            for (i, p) in points.enumerated().dropFirst() {
                let to = i == points.count - 1 ? (end ?? p) : p
                path.addPath(curve(points[i - 1], to))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: highlighted == tail.id ? 2.5 : 1.8, lineCap: .round))
            if points.count == 3 { ring(points[1], color, 3, in: &context) }
            if let end {
                context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)), with: .color(color))
            }
        }

        if let mac = route.mac { ring(projection.point(mac), .primary, 4, in: &context) }
        if let guardPlace = route.guardPlace { ring(projection.point(guardPlace), lit ? .route : .secondary, 4, in: &context) }
    }

    /// A gentle arc from a to b: the control point is pushed sideways by an
    /// eighth of the distance.
    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let control = CGPoint(x: mid.x + (b.y - a.y) / 8, y: mid.y - (b.x - a.x) / 8)
        path.addQuadCurve(to: b, control: control)
        return path
    }

    private func ring(_ p: CGPoint, _ color: Color, _ r: CGFloat, in context: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(circle, with: .color(color), lineWidth: 2)
    }
}

private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
