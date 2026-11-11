import Foundation

/// Whether traffic goes through Tor.
public enum Mode: String, Sendable, Equatable, CaseIterable, Codable {
    case direct, tor
}

/// Where Tor is.
public enum Status: Sendable, Equatable, Codable {
    case off
    case starting(step: String, progress: Double)
    case on
    /// Tor stopped; traffic is held back until it runs again.
    case blocked(reason: String)
    /// Tor could not start.
    case failed(reason: String)
}

extension Status {
    /// The reason the real engine gives while macOS waits for the user to
    /// allow the network extension; the UI offers to open System Settings.
    public static let allowExtensionReason = "Allow Tortuga's network extension in System Settings"
}

public enum BridgeKind: String, Sendable, Hashable, CaseIterable, Codable {
    case snowflake, obfs4, webtunnel

    public var title: String {
        switch self {
        case .snowflake: "Snowflake"
        case .obfs4: "obfs4"
        case .webtunnel: "WebTunnel"
        }
    }

    /// obfs4 and WebTunnel need bridge lines; Snowflake has built-in ones.
    public var needsLines: Bool { self != .snowflake }
}

public struct Relay: Sendable, Hashable, Codable {
    public var nickname: String
    /// ISO 3166 country code, like "DE".
    public var country: String
    public var address: String

    public init(nickname: String, country: String, address: String) {
        self.nickname = nickname
        self.country = country
        self.address = address
    }

    public var flag: String { Flag.emoji(country) }
}

/// An app, by its code-signing identifier. Two AppIDs are the same app when
/// their identifiers match; `path` and `name` only help to show it.
public struct AppID: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    /// Where the app is, for apps the system can't find by identifier.
    public var path: String?
    /// A name to show when the app isn't installed.
    public var name: String?

    public init(_ id: String, path: String? = nil, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
    }

    public static func == (a: AppID, b: AppID) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The part of the route every app shares: the bridge and the guard.
public struct Trunk: Sendable, Equatable, Codable {
    public var bridge: BridgeKind?
    public var guardRelay: Relay?

    public init(bridge: BridgeKind? = nil, guardRelay: Relay? = nil) {
        self.bridge = bridge
        self.guardRelay = guardRelay
    }
}

/// One app's own part of the route.
public struct AppRoute: Sendable, Equatable, Identifiable, Codable {
    public var app: AppID
    public var middle: Relay
    public var exit: Relay
    public var connections: Int
    public var lastActive: Date

    public var id: String { app.id }

    public init(app: AppID, middle: Relay, exit: Relay, connections: Int, lastActive: Date) {
        self.app = app
        self.middle = middle
        self.exit = exit
        self.connections = connections
        self.lastActive = lastActive
    }
}

public struct BridgeSettings: Sendable, Equatable, Codable {
    /// nil: no bridge.
    public var selected: BridgeKind?
    /// Saved lines by kind, each starting with "Bridge ".
    public var lines: [BridgeKind: [String]]

    public init(selected: BridgeKind? = nil, lines: [BridgeKind: [String]] = [:]) {
        self.selected = selected
        self.lines = lines
    }

    public func saved(_ kind: BridgeKind) -> [String] { lines[kind] ?? [] }
}

public enum DownloadState: String, Sendable, Equatable, Codable {
    case downloading, sharing, paused, done, failed
}

public struct Download: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var name: String
    public var size: Int64
    /// 0…1.
    public var done: Double
    /// Bytes per second.
    public var downRate: Int64
    public var upRate: Int64
    public var state: DownloadState
    public var error: String?

    public init(id: UUID = UUID(), name: String, size: Int64, done: Double = 0, downRate: Int64 = 0,
                upRate: Int64 = 0, state: DownloadState = .downloading, error: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.done = done
        self.downRate = downRate
        self.upRate = upRate
        self.state = state
        self.error = error
    }
}

public enum DownloadSource: Sendable, Equatable {
    case magnet(String)
    case file(URL)
}

public struct EngineState: Sendable, Equatable, Codable {
    public var mode: Mode = .direct
    public var status: Status = .off
    public var trunk = Trunk()
    public var apps: [AppRoute] = []
    public var bridges = BridgeSettings()
    public var exceptions: [AppID] = []
    public var downloads: [Download] = []
    /// False with the real engine until downloads move into the app (part 4).
    public var downloadsAvailable = true

    public init() {}

    public static let initial = EngineState()
}

public enum Flag {
    /// The flag emoji for a two-letter country code, or a white flag.
    public static func emoji(_ code: String) -> String {
        let letters = Array(code.uppercased().unicodeScalars)
        guard letters.count == 2, letters.allSatisfy({ (65...90).contains($0.value) }) else { return "🏳️" }
        var flag = String.UnicodeScalarView()
        for letter in letters {
            if let scalar = Unicode.Scalar(0x1F1A5 + letter.value) { flag.append(scalar) }
        }
        return String(flag)
    }
}
