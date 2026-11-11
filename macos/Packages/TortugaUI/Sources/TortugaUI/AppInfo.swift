import AppKit
import TortugaKit

/// Names and icons for apps, from the system (the engine sends only IDs).
@MainActor
enum AppInfo {
    static func url(_ app: AppID) -> URL? {
        if let path = app.path { return URL(fileURLWithPath: path) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
    }

    static func name(_ app: AppID) -> String {
        if let url = url(app) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return app.name ?? app.id
    }

    static func icon(_ app: AppID) -> NSImage {
        if let url = url(app) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    /// The AppID of an app the user picked in Finder.
    static func id(forAppAt url: URL) -> AppID? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return AppID(id, path: url.path, name: FileManager.default.displayName(atPath: url.path))
    }
}
