import SwiftUI
import TortugaKit
import UniformTypeIdentifiers

/// Apps that bypass Tor, with a plain warning about what that means.
struct ExceptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.state.exceptions.isEmpty {
                    Text("No exceptions: every app goes through Tor.").foregroundStyle(.secondary)
                }
                ForEach(model.state.exceptions) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: AppInfo.icon(app)).resizable().frame(width: 22, height: 22)
                        Text(AppInfo.name(app))
                        Spacer()
                        Button {
                            Task { await model.perform(.exceptions) { try await $0.removeException(app) } }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("remove.\(app.id)")
                    }
                    .padding(10)
                    .glassCard(cornerRadius: 14)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("exception.\(app.id)")
                }
                Button { choosing = true } label: { Label("Add App…", systemImage: "plus") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("exceptions.add")
                Text("These apps connect directly. Sites they reach see your IP address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.errors[.exceptions] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result, let app = AppInfo.id(forAppAt: url) else { return }
            Task { await model.perform(.exceptions) { try await $0.addException(app) } }
        }
        .navigationTitle("Exceptions")
    }
}
