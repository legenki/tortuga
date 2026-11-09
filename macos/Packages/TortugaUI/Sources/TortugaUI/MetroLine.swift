import AppKit
import SwiftUI
import TortugaKit

/// A route drawn as a metro line: stations evenly spaced, a flag above each
/// relay, and a title and detail under each station (not when compact).
struct MetroLine: View {
    struct Stop: Identifiable, Equatable {
        enum Kind: Equatable {
            case you, bridge(BridgeKind), relay, exit

            var isBridge: Bool {
                if case .bridge = self { true } else { false }
            }
        }

        var id: String
        var kind: Kind
        var title: String
        var detail: String
        var flag: String?
    }

    var stops: [Stop]
    var lit: Bool
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            if !compact, stops.contains(where: { $0.flag != nil }) {
                columns { Text($0.flag ?? " ").font(.callout) }
            }
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: compact ? 10 : 16)
            if !compact {
                columns { stop in
                    VStack(spacing: 1) {
                        Text(stop.title).font(.caption.weight(.semibold))
                        Text(stop.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stops.map { "\($0.title) \($0.detail)" }.joined(separator: ", "))
    }

    private func columns<Content: View>(@ViewBuilder _ content: @escaping (Stop) -> Content) -> some View {
        HStack(spacing: 0) {
            ForEach(stops) { stop in
                content(stop).lineLimit(1).frame(maxWidth: .infinity)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !stops.isEmpty else { return }
        let column = size.width / CGFloat(stops.count)
        let y = size.height / 2
        let radius = compact ? 4.0 : 6.0
        func x(_ i: Int) -> CGFloat { column * (CGFloat(i) + 0.5) }

        for i in stops.indices.dropFirst() {
            var path = Path()
            path.move(to: CGPoint(x: x(i - 1), y: y))
            path.addLine(to: CGPoint(x: x(i), y: y))
            let color: Color = !lit ? .secondary.opacity(0.35) : stops[i].kind.isBridge ? .bridge : .route
            let style = stops[i].kind == .bridge(.snowflake)
                ? StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round, dash: [1, compact ? 4 : 6])
                : StrokeStyle(lineWidth: compact ? 3 : 5, lineCap: .round)
            context.stroke(path, with: .color(color), style: style)
        }

        for (i, stop) in stops.enumerated() {
            let circle = Path(ellipseIn: CGRect(x: x(i) - radius, y: y - radius, width: radius * 2, height: radius * 2))
            let ring: Color = !lit ? .secondary : stop.kind == .you ? .primary : stop.kind.isBridge ? .bridge : .route
            let fill: Color = lit && stop.kind == .exit ? .route : Color(nsColor: .windowBackgroundColor)
            context.fill(circle, with: .color(fill))
            context.stroke(circle, with: .color(ring), lineWidth: compact ? 2 : 3)
        }
    }
}

extension MetroLine.Stop {
    /// The shared part: this Mac, the bridge if any, the guard once known.
    static func trunk(_ t: Trunk) -> [Self] {
        var stops = [Self(id: "you", kind: .you, title: "Mac", detail: "hidden")]
        if let bridge = t.bridge {
            stops.append(Self(id: "bridge", kind: .bridge(bridge), title: "Bridge", detail: bridge.title))
        }
        if let relay = t.guardRelay {
            stops.append(Self(id: "guard", kind: .relay, title: "Guard", detail: relay.country, flag: relay.flag))
        }
        return stops
    }

    /// One app's own part: middle and exit.
    static func tail(_ route: AppRoute) -> [Self] {
        [
            Self(id: "middle", kind: .relay, title: "Middle", detail: route.middle.country, flag: route.middle.flag),
            Self(id: "exit", kind: .exit, title: "Exit", detail: route.exit.country, flag: route.exit.flag),
        ]
    }

    static func full(_ t: Trunk, _ route: AppRoute) -> [Self] {
        trunk(t) + tail(route)
    }
}
