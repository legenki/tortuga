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
        let engine = ProxyEngine(control: SystemProxyControl(), store: DefaultsSettingsStore())
        Task { await engine.resume() }
        return engine
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
