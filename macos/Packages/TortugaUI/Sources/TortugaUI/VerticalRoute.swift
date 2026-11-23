import SwiftUI
import TortugaKit

/// One app's route, top to bottom: Mac, bridge, guard (the shared trunk, in
/// green and blue), then its middle and exit in the app's colour.
struct VerticalRoute: View {
    struct Stop: Identifiable, Equatable {
        enum Kind: Equatable { case mac, bridge, guardRelay, middle, exit }
        var kind: Kind
        var title: String
        var detail: String
        var flag: String?
        var id: String { title }
    }

    static func stops(_ trunk: Trunk, _ route: AppRoute) -> [Stop] {
        var stops = [Stop(kind: .mac, title: "Mac", detail: "hidden")]
        if let bridge = trunk.bridge {
            stops.append(Stop(kind: .bridge, title: "Bridge", detail: bridge.title))
        }
        if let relay = trunk.guardRelay {
            stops.append(Stop(kind: .guardRelay, title: "Guard", detail: RouteSummary.country(relay.country), flag: relay.flag))
        }
        stops.append(Stop(kind: .middle, title: "Middle", detail: route.middle.nickname, flag: route.middle.flag))
        stops.append(Stop(kind: .exit, title: "Exit", detail: route.exit.address, flag: route.exit.flag))
        return stops
    }

    let stops: [Stop]
    let color: Color
    var lit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { i, stop in
                HStack(spacing: 8) {
                    ZStack {
                        VStack(spacing: 0) {
                            Rectangle().fill(i == 0 ? .clear : line(stops[i].kind)).frame(width: 3)
                            Rectangle().fill(i == stops.count - 1 ? .clear : line(stops[i + 1].kind)).frame(width: 3)
                        }
                        Circle()
                            .fill(stop.kind == .exit && lit ? ring(stop.kind) : Color(nsColor: .windowBackgroundColor))
                            .strokeBorder(ring(stop.kind), lineWidth: 2.5)
                            .frame(width: 11, height: 11)
                    }
                    .frame(width: 12)
                    Text(stop.title).font(.caption.weight(.semibold))
                    if let flag = stop.flag { Text(flag).font(.caption) }
                    Text(stop.detail)
                        .font(stop.kind == .exit || stop.kind == .middle ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minHeight: 22)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stops.map { "\($0.title) \($0.detail)" }.joined(separator: ", "))
    }

    /// The segment that arrives at a stop of this kind.
    private func line(_ kind: Stop.Kind) -> Color {
        guard lit else { return .secondary.opacity(0.35) }
        return switch kind {
        case .bridge: .bridge
        case .mac, .guardRelay: .route
        case .middle, .exit: color
        }
    }

    private func ring(_ kind: Stop.Kind) -> Color {
        guard lit else { return .secondary }
        return switch kind {
        case .mac: .primary
        case .bridge: .bridge
        case .guardRelay: .route
        case .middle, .exit: color
        }
    }
}
