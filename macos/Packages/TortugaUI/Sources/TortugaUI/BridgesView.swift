import SwiftUI
import TortugaKit

struct BridgesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("A bridge hides that you use Tor. Pick one if Tor is blocked where you are.")
                    .foregroundStyle(.secondary)
                BridgeCard(kind: nil)
                ForEach(BridgeKind.allCases, id: \.self) { BridgeCard(kind: $0) }
                if let error = model.errors[.bridges] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .navigationTitle("Bridges")
    }
}

/// One choice: None, Snowflake, obfs4 or WebTunnel. The selected obfs4 or
/// WebTunnel card takes pasted lines, marks bad ones as they're typed, and
/// can get lines from bridges.torproject.org.
struct BridgeCard: View {
    @Environment(AppModel.self) private var model
    let kind: BridgeKind?
    @State private var draft = ""
    @State private var fetching = false

    private var selected: Bool { model.state.bridges.selected == kind }

    private var blurb: String {
        switch kind {
        case nil: "Connect to Tor directly."
        case .snowflake: "Built in. Works in most places."
        case .obfs4: "Paste lines from bridges.torproject.org, or get them here."
        case .webtunnel: "Looks like ordinary HTTPS. Paste lines, or get them here."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: select) {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.route : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind?.title ?? "None").font(.headline)
                            Text(blurb).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bridge.\(kind?.rawValue ?? "none")")
                Spacer()
                if let kind, kind.needsLines {
                    Text("\(model.state.bridges.saved(kind).count) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bridges.\(kind.rawValue).count")
                }
            }
            if let kind, kind.needsLines, selected {
                let parsed = BridgeLines.parse(draft, for: kind)
                TextEditor(text: $draft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                    .accessibilityIdentifier("bridges.\(kind.rawValue).lines")
                ForEach(parsed.errors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("bridges.error")
                }
                HStack {
                    Button("Save") { save(parsed.lines, kind) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.route)
                        .disabled(parsed.lines.isEmpty || !parsed.errors.isEmpty)
                        .accessibilityIdentifier("bridges.\(kind.rawValue).save")
                    Button(fetching ? "Getting…" : "Get lines") { fetch(kind) }
                        .buttonStyle(.glass)
                        .disabled(fetching)
                }
                if let error = model.errors[.fetch] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18, tint: selected ? Color.route.opacity(0.15) : nil)
    }

    private func select() {
        let kind = kind
        Task { await model.perform(.bridges) { try await $0.selectBridge(kind) } }
    }

    private func save(_ lines: [String], _ kind: BridgeKind) {
        Task {
            await model.perform(.bridges) { try await $0.saveBridgeLines(lines, for: kind) }
            if model.errors[.bridges] == nil { draft = "" }
        }
    }

    private func fetch(_ kind: BridgeKind) {
        Task {
            fetching = true
            if let lines = await model.fetchLines(kind) {
                await model.perform(.bridges) { try await $0.saveBridgeLines(lines, for: kind) }
            }
            fetching = false
        }
    }
}
