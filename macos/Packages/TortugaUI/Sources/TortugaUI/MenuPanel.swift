import AppKit
import SwiftUI
import TortugaKit

/// The app in front, other than Tortuga itself.
@MainActor @Observable
final class FrontApp {
    private(set) var app: AppID?
    @ObservationIgnored nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(running) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func update(_ running: NSRunningApplication?) {
        guard let running, let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        app = AppID(id, path: running.bundleURL?.path, name: running.localizedName)
    }
}

/// The menu bar panel: the status pill, a problem if any, the front app's
/// route (or an offer to send it through Tor), actions.
public struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var front = FrontApp()

    public init() {}

    public var body: some View {
        let state = model.state
        let app = front.app
        let listed = app.map { state.torApps.contains($0) } ?? false
        let route = listed ? app.flatMap { app in state.apps.first { $0.app == app } } : nil
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(showsGuard: false, fillsWidth: true, style: .standalone)
            ProblemBanner()
            if let app {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 20, height: 20)
                        Text(AppInfo.name(app)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        if let route {
                            Text("\(route.connections) conn.").font(.caption).foregroundStyle(.secondary)
                        } else if !listed {
                            Text("direct").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let route, state.status == .on {
                        VerticalRoute(stops: VerticalRoute.stops(state.trunk, route), color: .app(route.id))
                    } else if listed {
                        Text(state.status == .on ? "No traffic from \(AppInfo.name(app)) yet."
                                                 : "\(AppInfo.name(app)) is waiting for Tor.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(AppInfo.name(app)) connects directly: it isn't in Tortuga.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Send \(AppInfo.name(app)) through Tor", systemImage: "plus") {
                            Task { await model.addTorApp(app) }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.route)
                        .accessibilityIdentifier("menu.add")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 16)
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button("New circuit", systemImage: "arrow.clockwise") {
                        guard let app = route?.app else { return }
                        Task { await model.perform(.circuit) { try await $0.newCircuit(for: app) } }
                    }
                    .disabled(route == nil)
                    Button("Open Tortuga") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.glass)
            }
            if let error = model.errors[.circuit] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

/// The menu bar icon for a status.
public struct MenuBarLabel: View {
    let status: Status

    public init(status: Status) { self.status = status }

    public var body: some View {
        switch status {
        case .off: Image(systemName: "tortoise")
        case .starting: Image(systemName: "tortoise.fill").symbolEffect(.pulse)
        case .on: Image(systemName: "tortoise.fill")
        case .blocked, .failed: Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
