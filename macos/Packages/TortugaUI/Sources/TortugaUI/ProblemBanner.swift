import AppKit
import SwiftUI
import TortugaKit

/// When Tor is blocked or failed, or a mode or restart command failed: what
/// happened and the next step. Also a network extension update that waits
/// for the user, with what it costs.
struct ProblemBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.state.status
        let error = model.errors[.mode] ?? model.errors[.restart]
        let problem: String? = switch status {
        case .blocked(let reason): "\(reason) — Tor apps are blocked"
        case .failed(let reason): reason
        default: nil
        }
        Group {
            if problem != nil || error != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("problem")
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if problem != nil {
                        HStack(spacing: 8) {
                            if status == .failed(reason: Status.allowExtensionReason) {
                                Button("Open System Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(Color.route)
                            }
                            Button("Restart") {
                                Task { await model.perform(.restart) { try await $0.restart() } }
                            }
                            .accessibilityIdentifier("restart")
                            if case .failed = status {
                                Button("Bridges…") {
                                    model.section = .bridges
                                    openWindow(id: "main")
                                    NSApp.activate()
                                }
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(14)
                .frame(maxWidth: 460, alignment: .leading)
                .glassCard(cornerRadius: 18)
            }
            if let update = model.state.pendingUpdate {
                UpdateNotice(update: update)
            }
        }
    }
}

/// A network extension update waiting for the user: replacing the extension
/// while Tor is on lets traffic out without Tor for a few seconds, so it
/// happens only on "Update now".
struct UpdateNotice: View {
    @Environment(AppModel.self) private var model
    let update: ExtensionUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(update.title, systemImage: "arrow.down.circle.fill")
                .font(.callout.weight(.medium))
            Text(ExtensionUpdate.warning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Update now") {
                    Task { await model.perform(.update) { try await $0.finishUpdate() } }
                }
                .buttonStyle(.glassProminent)
                .tint(Color.route)
                .accessibilityIdentifier("finishUpdate")
                if let error = model.errors[.update] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .glassCard(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pendingUpdate")
    }
}
