import AppKit
import ServiceManagement
import SwiftUI
import TortugaKit

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
            #if DEBUG
            Tab("Demo", systemImage: "ladybug") { DemoSettings() }
            #endif
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage("showInDock") private var showInDock = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show in Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, on in NSApp.setActivationPolicy(on ? .regular : .accessory) }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

struct DownloadSettings: View {
    @AppStorage("downloadsFolder") private var folder =
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Tortuga").path

    var body: some View {
        Form {
            LabeledContent("Downloads folder") {
                HStack {
                    Text(folder).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: choose)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tortoise.fill").font(.system(size: 44)).foregroundStyle(Color.route)
            Text("Tortuga").font(.title2.weight(.bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Hides your IP. Not Tor Browser.")
            Link("github.com/legenki/tortuga", destination: URL(string: "https://github.com/legenki/tortuga")!)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
/// Debug builds only: swap the DemoEngine scenario, or go back to the real
/// engine (takes effect when Tortuga next opens).
struct DemoSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("scenario") private var scenario = "real"

    var body: some View {
        Form {
            Picker("Engine", selection: $scenario) {
                Text("Real (Tor)").tag("real")
                ForEach(Scenario.allCases) { Text("Demo: \($0.rawValue)").tag($0.rawValue) }
            }
            .onChange(of: scenario) { _, name in
                if let demo = Scenario(rawValue: name) { model.replace(engine: DemoEngine.running(demo)) }
            }
            if scenario == "real" {
                Text("Quit and reopen Tortuga to use the real engine.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
