import AppKit
import SwiftUI
import TortugaKit

/// The status with its dot, and the next step when something is wrong.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(state.status.color).frame(width: 8, height: 8)
                Text(state.status.text(bridge: state.trunk.bridge ?? state.bridges.selected))
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("status")
                Spacer(minLength: 0)
                switch state.status {
                case .blocked, .failed:
                    if state.status == .failed(reason: Status.allowExtensionReason) {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.route)
                    }
                    Button("Restart") {
                        Task { await model.perform(.restart) { try await $0.restart() } }
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("restart")
                    if case .failed = state.status {
                        Button("Bridges…") {
                            model.section = .bridges
                            openWindow(id: "main")
                        }
                        .buttonStyle(.glass)
                    }
                default:
                    EmptyView()
                }
            }
            if let error = model.errors[.mode] ?? model.errors[.restart] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
