import SwiftUI
import TortugaKit

/// The shared trunk, then a row per app: active first, idle folded, waiting last.
struct RouteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let state = model.state
        let list = RouteList(apps: state.apps, torApps: state.torApps, now: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusLine()
                VStack(alignment: .leading, spacing: 8) {
                    RouteMap(state: state, highlighted: model.hoveredApp ?? model.expandedApp,
                             focused: model.expandedApp) { id in
                        withAnimation(.snappy) { model.expandedApp = id }
                    }
                    .frame(height: 240)
                    if let guardRelay = state.trunk.guardRelay {
                        Text(guardLine(guardRelay, bridge: state.trunk.bridge))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("route.guard")
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 20)
                if state.status == .on, list.active.isEmpty, list.idle.isEmpty {
                    Text("Apps appear here as they connect.").foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(list.active) { AppRow(route: $0, trunk: state.trunk, lit: state.status == .on, expanded: $model.expandedApp) }
                }
                if !list.idle.isEmpty {
                    DisclosureGroup("Idle (\(list.idle.count))") {
                        VStack(spacing: 8) {
                            ForEach(list.idle) { AppRow(route: $0, trunk: state.trunk, lit: state.status == .on, expanded: $model.expandedApp) }
                        }
                        .padding(.top, 8)
                    }
                }
                if let error = model.errors[.circuit] ?? model.errors[.apps] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .navigationTitle("Route")
    }

    /// "Guard 🇩🇪 Germany · via Snowflake".
    private func guardLine(_ relay: Relay, bridge: BridgeKind?) -> String {
        let via = bridge.map { " · via \($0.title)" } ?? ""
        return "Guard \(relay.flag) \(RouteSummary.country(relay.country))\(via)"
    }
}

/// One app: icon, name, its middle → exit; click for details and actions.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    let route: AppRoute
    let trunk: Trunk
    /// Off while Tor isn't on: the route is drawn grey, not as if it worked.
    let lit: Bool
    @Binding var expanded: String?

    private var isOpen: Bool { expanded == route.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(lit ? Color.app(route.id) : .secondary).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Image(nsImage: AppInfo.icon(route.app)).resizable().frame(width: 24, height: 24)
                Text(AppInfo.name(route.app))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                MetroLine(stops: MetroLine.Stop.tail(route), lit: lit, compact: true)
                Text("\(route.middle.flag) → \(route.exit.flag)")
                    .font(.callout)
                    .accessibilityIdentifier("row.exit.\(route.id)")
                    .accessibilityLabel(route.exit.address)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .onTapGesture(perform: toggle)
            // Not a Button: a button merges its parts into one accessibility
            // element, and the exit should stay readable on its own.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggle)
            .accessibilityIdentifier("route.row.\(route.id)")

            if isOpen {
                MetroLine(stops: MetroLine.Stop.full(trunk, route), lit: lit)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Middle").foregroundStyle(.secondary)
                        Text("\(route.middle.nickname) · \(route.middle.address)")
                    }
                    GridRow {
                        Text("Exit").foregroundStyle(.secondary)
                        Text("\(route.exit.nickname) · \(route.exit.address)")
                    }
                    GridRow {
                        Text("Connections").foregroundStyle(.secondary)
                        Text("\(route.connections)")
                    }
                }
                .font(.caption.monospaced())
                HStack {
                    Button("New circuit", action: newCircuit)
                        .accessibilityIdentifier("circuit.\(route.id)")
                    Button("Remove from Tortuga", action: exclude)
                        .accessibilityIdentifier("exclude.\(route.id)")
                }
                .buttonStyle(.glass)
            }
        }
        .onHover { inside in
            if inside { model.hoveredApp = route.id } else if model.hoveredApp == route.id { model.hoveredApp = nil }
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
        .contextMenu {
            Button("New circuit", action: newCircuit)
            Button("Remove from Tortuga", action: exclude)
        }
    }

    private func toggle() {
        withAnimation(.snappy) { expanded = isOpen ? nil : route.id }
    }

    private func newCircuit() {
        let app = route.app
        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
    }

    private func exclude() {
        let app = route.app
        Task { await model.removeTorApp(app) }
    }
}
