import Foundation
import TortugaKit

/// What the extension needs from the app: the user's settings and where
/// the helper is.
public struct ProxyConfiguration: Codable, Sendable, Equatable {
    public var bridge: BridgeKind?
    public var lines: [BridgeKind: [String]]
    /// Signing identifiers of the apps that go through Tor.
    public var torApps: [String]
    /// tortuga-helper in the app's copy of the extension (spike Q5).
    public var helperPath: String
    /// pt/ (lyrebird, pt_config.json) next to it.
    public var ptDir: String

    public init(bridge: BridgeKind?, lines: [BridgeKind: [String]], torApps: [String], helperPath: String, ptDir: String) {
        self.bridge = bridge
        self.lines = lines
        self.torApps = torApps
        self.helperPath = helperPath
        self.ptDir = ptDir
    }

    static let providerKey = "configuration"

    /// For `NETunnelProviderProtocol.providerConfiguration`.
    public func providerConfiguration() throws -> [String: Any] {
        [Self.providerKey: try JSONEncoder().encode(self)]
    }

    public init?(providerConfiguration: [String: Any]?) {
        guard let data = providerConfiguration?[Self.providerKey] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}

/// The part of the UI's state that only the extension knows.
public struct ExtensionState: Codable, Sendable, Equatable {
    public var status: Status
    public var trunk: Trunk
    public var apps: [AppRoute]
    /// Signing identifiers of apps that went direct in the last hour (not
    /// in the Tor list), most recent first.
    public var seenDirect: [String]

    public init(status: Status, trunk: Trunk, apps: [AppRoute], seenDirect: [String] = []) {
        self.status = status
        self.trunk = trunk
        self.apps = apps
        self.seenDirect = seenDirect
    }

    /// An extension from before the Tor list sends no `seenDirect`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        trunk = try container.decode(Trunk.self, forKey: .trunk)
        apps = try container.decode([AppRoute].self, forKey: .apps)
        seenDirect = try container.decodeIfPresent([String].self, forKey: .seenDirect) ?? []
    }

    public static let idle = ExtensionState(status: .off, trunk: Trunk(), apps: [])
}

public enum ExtensionCommand: Codable, Sendable, Equatable {
    case configure(ProxyConfiguration)
    case restart
    /// nil: every app.
    case newCircuit(app: String?)
    case fetchBridgeLines(BridgeKind)
}

public enum ExtensionReply: Codable, Sendable, Equatable {
    case ok
    case lines([String])
    case failure(String)
}

/// JSON over XPC.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
