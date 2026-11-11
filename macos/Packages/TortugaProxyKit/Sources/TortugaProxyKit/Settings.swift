import Foundation
import TortugaKit

/// The user's choices, kept by the app.
public struct StoredSettings: Codable, Sendable, Equatable {
    public var mode: Mode = .direct
    public var bridge: BridgeKind? = .snowflake
    public var lines: [BridgeKind: [String]] = [:]
    public var exceptions: [AppID] = []

    public init() {}
}

public protocol SettingsStore: Sendable {
    func load() -> StoredSettings
    func save(_ settings: StoredSettings)
}

/// StoredSettings as JSON in UserDefaults.
public struct DefaultsSettingsStore: SettingsStore {
    public static let key = "proxySettings"

    public init() {}

    public func load() -> StoredSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(StoredSettings.self, from: data) else { return StoredSettings() }
        return settings
    }

    public func save(_ settings: StoredSettings) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
