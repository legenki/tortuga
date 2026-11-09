import AppKit
import SwiftUI
import TortugaKit

/// The app in front, other than Tortuga itself.
@MainActor @Observable
final class FrontApp {
    private(set) var app: AppID?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(running) }
        }
    }

    private func update(_ running: NSRunningApplication?) {
        guard let running, let id = running.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        app = AppID(id, path: running.bundleURL?.path, name: running.localizedName)
    }
}

/// The menu bar panel: switch, status, the front app's route, actions.
public struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var front = FrontApp()

    public init() {}

    public var body: some View {
        let state = model.state
        let app = front.app
        let route = app.flatMap { app in state.apps.first { $0.app == app } }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tortuga").font(.headline)
                Spacer()
                ModeSwitch()
            }
            StatusLine()
            if let app {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppInfo.name(app)).font(.subheadline.weight(.semibold))
                    if let route {
                        MetroLine(stops: MetroLine.Stop.full(state.trunk, route), lit: true)
                        Text("Exit \(route.exit.address) · \(route.exit.country)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else if state.exceptions.contains(app) {
                        Text("Connects directly: it's an exception.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No traffic from \(AppInfo.name(app)) yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 16)
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button("New circuit") {
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
