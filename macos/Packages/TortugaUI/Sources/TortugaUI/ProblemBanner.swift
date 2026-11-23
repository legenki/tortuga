import AppKit
import SwiftUI
import TortugaKit

/// When Tor is blocked or failed, or a mode or restart command failed: what
/// happened and the next step.
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
    }
}
