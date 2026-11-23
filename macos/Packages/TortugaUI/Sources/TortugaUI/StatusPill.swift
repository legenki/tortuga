import SwiftUI
import TortugaKit

/// The status as a glass capsule, and the button that turns Tor on or off.
struct StatusPill: View {
    /// What the pill says, worked out from the state (tested on its own).
    struct Content: Equatable {
        enum Tone: Equatable { case off, starting, on, problem }

        var tone: Tone
        var title: String
        var detail: String
        /// Bootstrap progress, 0...1, while starting.
        var progress: Double?
        /// A click turns Tor on (else off).
        var turnsOn: Bool

        var label: String { detail.isEmpty ? title : "\(title), \(detail)" }

        init(state: EngineState, now: Date, showsGuard: Bool) {
            progress = nil
            turnsOn = false
            switch state.status {
            case .off:
                tone = .off
                title = "Direct"
                detail = "turn on Tor"
                turnsOn = true
            case .starting(let step, let p):
                tone = .starting
                title = "Connecting… \(Int(p * 100))%"
                detail = step
                progress = p
            case .on:
                tone = .on
                title = "Tor on"
                let n = RouteList(apps: state.apps, torApps: state.torApps, now: now).active.count
                var parts = [n == 0 ? "no traffic yet" : n == 1 ? "1 app" : "\(n) apps"]
                if showsGuard, let relay = state.trunk.guardRelay {
                    parts.append("Guard \(relay.flag) \(RouteSummary.country(relay.country))")
                }
                detail = parts.joined(separator: " · ")
            case .blocked(let reason):
                tone = .problem
                title = reason
                detail = "Tor apps are blocked"
            case .failed(let reason):
                tone = .problem
                title = reason
                detail = ""
            }
        }
    }

    @Environment(AppModel.self) private var model
    var showsGuard: Bool
    /// Fills the width it is given (the menu panel) instead of hugging its text.
    var fillsWidth = false

    var body: some View {
        let content = Content(state: model.state, now: .now, showsGuard: showsGuard)
        Button { toggle(content) } label: {
            HStack(spacing: 8) {
                dot(content.tone)
                Text(content.title).font(.callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
                if !content.detail.isEmpty {
                    Text("· \(content.detail)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if fillsWidth { Spacer(minLength: 0) }
                Image(systemName: "power").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: fillsWidth ? .infinity : 320)
            .background(alignment: .leading) {
                if let progress = content.progress {
                    GeometryReader { geo in
                        Color.caution.opacity(0.25).frame(width: geo.size.width * progress)
                    }
                }
            }
            .clipShape(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background { Color.clear.glassEffect(.regular.interactive(), in: .capsule) }
        .accessibilityLabel(content.label)
        .accessibilityHint(content.turnsOn ? "Turns Tor on" : "Turns Tor off")
        .accessibilityIdentifier("status")
    }

    @ViewBuilder
    private func dot(_ tone: Content.Tone) -> some View {
        switch tone {
        case .off: Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        case .starting: Circle().fill(Color.caution).frame(width: 8, height: 8)
        case .on: Circle().fill(Color.route).frame(width: 8, height: 8)
            .background(Circle().fill(Color.route.opacity(0.25)).frame(width: 14, height: 14))
        case .problem: Circle().fill(.red).frame(width: 8, height: 8)
        }
    }

    private func toggle(_ content: Content) {
        let mode: Mode = content.turnsOn ? .tor : .direct
        Task { await model.perform(.mode) { try await $0.setMode(mode) } }
    }
}
