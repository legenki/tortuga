import AppKit
import SwiftUI
import TortugaKit

/// The glass panel on the left of the map: the Tor list, a way to add apps,
/// and the apps seen going direct.
struct AppPanel: View {
    @Environment(AppModel.self) private var model
    static let width: CGFloat = 288

    var body: some View {
        let state = model.state
        let list = RouteList(apps: state.apps, torApps: state.torApps, now: .now)
        let lit = state.status == .on
        let direct = state.seenDirect.filter(AppInfo.isApp)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                title("THROUGH TOR")
                if state.torApps.isEmpty {
                    Text("No apps go through Tor. Add one with + Add app…")
                        .font(.caption).foregroundStyle(.secondary).padding(9)
                }
                ForEach(list.active) { TorAppRow(app: listed($0.app), route: $0, lit: lit, idle: false) }
                ForEach(list.idle) { TorAppRow(app: listed($0.app), route: $0, lit: lit, idle: true) }
                ForEach(list.waiting) { TorAppRow(app: $0, route: nil, lit: lit, idle: false) }
                Button(action: pickApp) {
                    Text("+ Add app…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .accessibilityIdentifier("add.app")
                if let error = model.errors[.apps] {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 9)
                }
                if !direct.isEmpty {
                    title("GOING DIRECT", note: "seen in the last hour").padding(.top, 10)
                    ForEach(direct) { DirectRow(app: $0) }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .glassCard(cornerRadius: 18)
    }

    /// The listed AppID for a route's app, so names and icons come from the list.
    private func listed(_ app: AppID) -> AppID {
        model.state.torApps.first { $0 == app } ?? app
    }

    private func title(_ text: String, note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.caption2.weight(.semibold)).tracking(0.5)
            if let note { Text("· \(note)").font(.caption2) }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Send through Tor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addApp(at: url) }
    }
}

/// A listed app. Click to open its route; the pointer over it shows −.
struct TorAppRow: View {
    @Environment(AppModel.self) private var model
    let app: AppID
    let route: AppRoute?
    let lit: Bool
    let idle: Bool
    @State private var hovering = false

    private var isOpen: Bool { model.expandedApp == app.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle().fill(lit && route != nil && !idle ? Color.app(app.id) : .secondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 24, height: 24)
                Text(AppInfo.name(app)).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                if idle {
                    Text("idle").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).overlay(Capsule().strokeBorder(.secondary.opacity(0.4)))
                } else if route == nil {
                    Text("no traffic yet").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let route, lit {
                    // Stays while hovered: the UI tests read it after a click.
                    Text("\(route.middle.flag) → \(route.exit.flag)")
                        .font(.callout)
                        .accessibilityIdentifier("row.exit.\(app.id)")
                        .accessibilityLabel(route.exit.address)
                }
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Tortuga")
                    .accessibilityLabel("Remove from Tortuga")
                    .accessibilityIdentifier("remove.\(app.id)")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(isOpen ? 0.10 : hovering ? 0.05 : 0)))
            .contentShape(.rect)
            .onTapGesture(perform: toggle)
            // Not a Button: a button merges its parts into one accessibility
            // element, and the exit should stay readable on its own.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggle)
            .accessibilityIdentifier("route.row.\(app.id)")

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    if let route, lit {
                        VerticalRoute(stops: VerticalRoute.stops(model.state.trunk, route), color: .app(app.id))
                        Text("\(route.connections) connections").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(lit ? "No traffic yet." : "Tor is off.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if route != nil, lit {
                            Button("New circuit", systemImage: "arrow.clockwise", action: newCircuit)
                                .accessibilityIdentifier("circuit.\(app.id)")
                        }
                        TrashButton(action: remove)
                            .accessibilityIdentifier("trash.\(app.id)")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    if let error = model.errors[.circuit] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.leading, 44)
                .padding(.bottom, 8)
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { model.hoveredApp = app.id } else if model.hoveredApp == app.id { model.hoveredApp = nil }
        }
        .contextMenu {
            Button("New circuit", action: newCircuit).disabled(!(lit && route != nil))
            Button("Remove from Tortuga", action: remove)
        }
        .accessibilityAction(named: "Remove from Tortuga", remove)
        .onDisappear { if model.hoveredApp == app.id { model.hoveredApp = nil } }
    }

    private func toggle() {
        withAnimation(.snappy) { model.expandedApp = isOpen ? nil : app.id }
    }

    private func newCircuit() {
        let app = app
        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
    }

    private func remove() {
        let app = app
        Task { await model.removeTorApp(app) }
    }
}

/// The trash icon that removes an app from the list; red under the pointer.
struct TrashButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").foregroundStyle(hovering ? Color.red : Color.primary)
        }
        .tint(hovering ? .red : nil)
        .help("Remove from Tortuga")
        .accessibilityLabel("Remove from Tortuga")
        .onHover { hovering = $0 }
    }
}

/// An unlisted app seen going direct, with + to send it through Tor.
struct DirectRow: View {
    @Environment(AppModel.self) private var model
    let app: AppID

    var body: some View {
        HStack(spacing: 9) {
            Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .frame(width: 8, height: 8)
            Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 24, height: 24)
            Text(AppInfo.name(app)).font(.body.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await model.addTorApp(app) }
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.route)
            }
            .buttonStyle(.plain)
            .help("Send through Tor")
            .accessibilityLabel("Send \(AppInfo.name(app)) through Tor")
            .accessibilityIdentifier("add.\(app.id)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .opacity(0.8)
    }
}
