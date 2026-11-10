import SwiftUI
import TortugaKit

/// Torrents: drop a .torrent file or a magnet link on the screen to add one.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !model.state.downloadsAvailable {
                    Text("Downloads come in a later version.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                if model.state.downloadsAvailable, model.state.downloads.isEmpty {
                    Text("Drop a .torrent file or a magnet link here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(model.state.downloads) { DownloadRow(download: $0) }
                if let error = model.errors[.downloads] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Torrents don't go through Tor: other people in the swarm see your IP address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                let source: DownloadSource = url.isFileURL ? .file(url) : .magnet(url.absoluteString)
                Task { await model.perform(.downloads) { try await $0.addDownload(source) } }
            }
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.route, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
            }
        }
        .navigationTitle("Downloads")
    }
}

struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let download: Download

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(download.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                controls
            }
            ProgressView(value: download.done)
                .tint(download.state == .sharing ? Color.bridge : Color.route)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: download.size, countStyle: .file)
        let percent = Int(download.done * 100)
        switch download.state {
        case .downloading: return "\(percent)% of \(size) · ↓ \(rate(download.downRate))"
        case .sharing: return "Sharing · ↑ \(rate(download.upRate)) · stops at ratio 1.0"
        case .paused: return "Paused at \(percent)% of \(size)"
        case .done: return "Done · \(size)"
        case .failed: return download.error ?? "Failed"
        }
    }

    private func rate(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s"
    }

    @ViewBuilder
    private var controls: some View {
        let id = download.id
        HStack(spacing: 6) {
            if download.state == .downloading || download.state == .sharing {
                command("pause.fill", "Pause") { try await $0.pauseDownload(id) }
            }
            if download.state == .paused {
                command("play.fill", "Resume") { try await $0.resumeDownload(id) }
            }
            command("xmark", "Remove") { try await $0.removeDownload(id) }
        }
    }

    private func command(_ symbol: String, _ label: String,
                         _ action: @escaping @Sendable (any TortugaEngine) async throws -> Void) -> some View {
        Button {
            Task { await model.perform(.downloads, action) }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }
}
