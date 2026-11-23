import Foundation
import TortugaKit

/// The user's choices, kept by the app.
public struct StoredSettings: Codable, Sendable, Equatable {
    public var mode: Mode = .direct
    public var bridge: BridgeKind? = .snowflake
    public var lines: [BridgeKind: [String]] = [:]
    /// The apps that go through Tor. nil: never set (filled with the
    /// installed browsers on first load).
    public var torApps: [AppID]?
    /// Exceptions saved by Tortuga 0.3 and older, read only to leave those
    /// apps out of the first list. Never written.
    public var legacyExceptions: [AppID] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, bridge, lines, torApps
        case legacyExceptions = "exceptions"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .direct
        bridge = try c.decodeIfPresent(BridgeKind.self, forKey: .bridge)
        lines = try c.decodeIfPresent([BridgeKind: [String]].self, forKey: .lines) ?? [:]
        torApps = try c.decodeIfPresent([AppID].self, forKey: .torApps)
        legacyExceptions = try c.decodeIfPresent([AppID].self, forKey: .legacyExceptions) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(bridge, forKey: .bridge)
        try c.encode(lines, forKey: .lines)
        try c.encodeIfPresent(torApps, forKey: .torApps)
    }
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
