import AppKit
import SwiftUI
import TortugaKit
import TortugaUI

@main
struct TortugaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(engine: DemoEngine.running(TortugaApp.scenario))

    /// `-scenario <name>` on the command line, or the Demo tab's choice.
    static var scenario: Scenario {
        UserDefaults.standard.string(forKey: "scenario").flatMap(Scenario.init(rawValue:)) ?? .normal
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

        #if DEBUG
        Window("Spike", id: "spike") {
            SpikeWindow()
        }
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "spike") ? .presented : .suppressed)
        #endif
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
