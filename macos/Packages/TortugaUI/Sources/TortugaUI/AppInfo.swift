import AppKit
import TortugaKit

/// Names and icons for apps, from the system (the engine sends only IDs).
@MainActor
enum AppInfo {
    // Looked up once per app ID: Finder and the icon cache are slow, and
    // views ask on every redraw. Apps rarely change, so nothing is evicted.
    private static var urls: [String: URL?] = [:]
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]
    private static var apps: [String: Bool] = [:]

    static func url(_ app: AppID) -> URL? {
        if let known = urls[app.id] { return known }
        let url = app.path.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
        urls[app.id] = .some(url)
        return url
    }

    static func name(_ app: AppID) -> String {
        if let known = names[app.id] { return known }
        let name: String
        if let url = url(app) {
            let shown = FileManager.default.displayName(atPath: url.path)
            name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
        } else {
            name = app.name ?? app.id
        }
        names[app.id] = name
        return name
    }

    static func icon(_ app: AppID) -> NSImage {
        if let known = icons[app.id] { return known }
        let icon: NSImage
        if let url = url(app) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        icons[app.id] = icon
        return icon
    }

    /// The AppID of an app the user picked in Finder.
    static func id(forAppAt url: URL) -> AppID? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return AppID(id, path: url.path, name: FileManager.default.displayName(atPath: url.path))
    }

    /// Whether the system finds an app bundle for it (daemons have none).
    static func isApp(_ app: AppID) -> Bool {
        if let known = apps[app.id] { return known }
        let isApp = url(app)?.pathExtension == "app"
        apps[app.id] = isApp
        return isApp
    }
}
