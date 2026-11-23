import AppKit
import SwiftUI
import TortugaKit
import TortugaProxyKit
import TortugaUI

@main
struct TortugaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(engine: TortugaApp.makeEngine())

    /// `-scenario <name>` (UI tests) or the Demo tab's choice runs DemoEngine;
    /// otherwise the real engine.
    static func makeEngine() -> any TortugaEngine {
        if let name = UserDefaults.standard.string(forKey: "scenario"), let scenario = Scenario(rawValue: name) {
            return DemoEngine.running(scenario)
        }
        let engine = ProxyEngine(control: SystemProxyControl(), store: DefaultsSettingsStore(),
                                 installedBrowsers: TortugaApp.installedBrowsers)
        Task { await engine.resume() }
        return engine
    }

    /// Apps that open https links, as the first Tor list.
    nonisolated static func installedBrowsers() -> [AppID] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        let candidates = urls.compactMap { url -> InstalledBrowsers.Candidate? in
            // Can't be routed: the extension matches by identifier.
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return InstalledBrowsers.Candidate(id: id, path: url.path,
                                               name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        }
        // No paths in the first list: Safari's moves between macOS versions, and browsers are found by identifier.
        return InstalledBrowsers.pick(candidates, own: Bundle.main.bundleIdentifier)
            .map { AppID($0.id, name: $0.name) }
    }

    /// The window opens at launch the first time (for the welcome card), or
    /// when asked with `-openWindowAtLaunch YES` (UI tests).
    private static var openWindowAtLaunch: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: "didShowWelcome") || defaults.bool(forKey: "openWindowAtLaunch")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            MenuBarLabel(status: model.state.status)
        }
        .menuBarExtraStyle(.window)

        Window("Tortuga", id: "main") {
            MainWindow().environment(model)
        }
        .defaultLaunchBehavior(Self.openWindowAtLaunch ? .presented : .suppressed)

        Settings {
            SettingsView().environment(model)
        }

    }
}

/// Runs as a menu bar app (no Dock icon) unless Settings says otherwise.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
