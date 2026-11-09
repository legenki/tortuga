import SwiftUI
import TortugaKit

/// The shared trunk, then a row per app: active first, idle folded, excepted last.
struct RouteView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: String?

    var body: some View {
        let state = model.state
        let list = RouteList(apps: state.apps, exceptions: state.exceptions, now: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusLine()
                MetroLine(stops: MetroLine.Stop.trunk(state.trunk), lit: state.status == .on)
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                if state.status == .on, list.active.isEmpty, list.idle.isEmpty {
                    Text("Apps appear here as they connect.").foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(list.active) { AppRow(route: $0, trunk: state.trunk, expanded: $expanded) }
                    }
                }
                if !list.idle.isEmpty {
                    DisclosureGroup("Idle (\(list.idle.count))") {
                        VStack(spacing: 8) {
                            ForEach(list.idle) { AppRow(route: $0, trunk: state.trunk, expanded: $expanded) }
                        }
                        .padding(.top, 8)
                    }
                }
                ForEach(list.excepted) { ExceptedRow(app: $0) }
                if let error = model.errors[.circuit] ?? model.errors[.exceptions] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .navigationTitle("Route")
    }
}

/// One app: icon, name, its middle → exit; click for details and actions.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    let route: AppRoute
    let trunk: Trunk
    @Binding var expanded: String?

    private var isOpen: Bool { expanded == route.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: AppInfo.icon(route.app)).resizable().frame(width: 24, height: 24)
                Text(AppInfo.name(route.app))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                MetroLine(stops: MetroLine.Stop.tail(route), lit: true, compact: true)
                Text("\(route.middle.flag) → \(route.exit.flag)")
                    .font(.callout)
                    .accessibilityIdentifier("row.exit.\(route.id)")
                    .accessibilityLabel(route.exit.address)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy) { expanded = isOpen ? nil : route.id } }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("route.row.\(route.id)")

            if isOpen {
                MetroLine(stops: MetroLine.Stop.full(trunk, route), lit: true)
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
                    Button("Exclude from Tor", action: exclude)
                        .accessibilityIdentifier("exclude.\(route.id)")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contextMenu {
            Button("New circuit", action: newCircuit)
            Button("Exclude from Tor", action: exclude)
        }
    }

    private func newCircuit() {
        let app = route.app
        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
    }

    private func exclude() {
        let app = route.app
        Task { await model.perform(.exceptions) { try await $0.addException(app) } }
    }
}

/// An excepted app at the end of the Route list: dimmed, marked direct.
struct ExceptedRow: View {
    let app: AppID

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 24, height: 24)
            Text(AppInfo.name(app)).font(.body.weight(.semibold))
            Spacer()
            Text("direct").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(12)
        .opacity(0.6)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
