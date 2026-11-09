import SwiftUI
import TortugaKit

/// Direct / Tor as two glass capsules; the current one is prominent.
struct ModeSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                option(.direct, "Direct")
                option(.tor, "Tor")
            }
        }
    }

    @ViewBuilder
    private func option(_ mode: Mode, _ title: String) -> some View {
        let button = Button(title) {
            Task { await model.perform(.mode) { try await $0.setMode(mode) } }
        }
        .accessibilityIdentifier("mode.\(mode.rawValue)")
        if model.state.mode == mode {
            button.buttonStyle(.glassProminent).tint(mode == .tor ? Color.route : .secondary)
                .accessibilityAddTraits(.isSelected)
        } else {
            button.buttonStyle(.glass)
        }
    }
}
