import Foundation
import TortugaKit

/// What the extension needs from the app: the user's settings and where
/// the helper is.
public struct ProxyConfiguration: Codable, Sendable, Equatable {
    public var bridge: BridgeKind?
    public var lines: [BridgeKind: [String]]
    /// Signing identifiers of excepted apps.
    public var exceptions: [String]
    /// tortuga-helper in the app's copy of the extension (spike Q5).
    public var helperPath: String
    /// pt/ (lyrebird, pt_config.json) next to it.
    public var ptDir: String

    public init(bridge: BridgeKind?, lines: [BridgeKind: [String]], exceptions: [String], helperPath: String, ptDir: String) {
        self.bridge = bridge
        self.lines = lines
        self.exceptions = exceptions
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

    public init(status: Status, trunk: Trunk, apps: [AppRoute]) {
        self.status = status
        self.trunk = trunk
        self.apps = apps
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
