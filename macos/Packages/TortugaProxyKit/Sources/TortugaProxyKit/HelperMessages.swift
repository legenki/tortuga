import Foundation

/// Native-messaging framing, as the helper reads and writes it: a 4-byte
/// little-endian length, then that many bytes of JSON.
public enum Framing {
    public static func encode(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }
}

/// Splits a byte stream into frames, however the bytes arrive.
public struct FrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

public enum HelperRequest: Sendable, Equatable {
    case hello
    /// `bridge`: "none", "snowflake", "obfs4" or "webtunnel".
    case start(bridge: String, lines: [String])
    case stop
    case newCircuit(site: String)
    case resolve(String)
    case fetchBridges(kind: String)

    func encoded(id: UInt64) -> Data {
        let (type, payload): (String, [String: Any]?) = switch self {
        case .hello: ("hello", ["protocol": 1])
        case .start(let bridge, let lines): ("tor.start", ["bridge": ["kind": bridge, "lines": lines]])
        case .stop: ("tor.stop", nil)
        case .newCircuit(let site): ("tor.newCircuit", ["site": site])
        case .resolve(let name): ("tor.resolve", ["name": name])
        case .fetchBridges(let kind): ("bridges.fetch", ["kind": kind])
        }
        var message: [String: Any] = ["id": id, "type": type]
        if let payload { message["payload"] = payload }
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }
}

public struct HelperHop: Sendable, Equatable {
    public var role: String
    public var id: String
    public var addr: String?
    public var country: String?
}

public enum HelperEvent: Sendable, Equatable {
    case hello(version: String, features: [String])
    case ok
    case torStatus(phase: String, percent: Int, blocked: String?)
    case torReady(socksPort: Int)
    case circuit(site: String, bridge: String?, hops: [HelperHop])
    case resolved([String])
    case bridgeLines([String])
    case error(code: String, message: String)
    /// A message this client doesn't know (a newer helper's).
    case other(String)
}

public struct HelperMessage: Sendable, Equatable {
    public var id: UInt64?
    public var event: HelperEvent

    public static func parse(_ data: Data) -> HelperMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let p = object["payload"] as? [String: Any] ?? [:]
        let id = (object["id"] as? NSNumber)?.uint64Value
        let event: HelperEvent
        switch type {
        case "hello":
            event = .hello(version: p["version"] as? String ?? "", features: p["features"] as? [String] ?? [])
        case "ok":
            event = .ok
        case "tor.status":
            event = .torStatus(phase: p["phase"] as? String ?? "", percent: p["percent"] as? Int ?? 0, blocked: p["blocked"] as? String)
        case "tor.ready":
            event = .torReady(socksPort: p["socksPort"] as? Int ?? 0)
        case "circuit":
            let hops = (p["hops"] as? [[String: Any]] ?? []).map {
                HelperHop(role: $0["role"] as? String ?? "", id: $0["id"] as? String ?? "",
                          addr: $0["addr"] as? String, country: $0["country"] as? String)
            }
            event = .circuit(site: p["site"] as? String ?? "", bridge: p["bridge"] as? String, hops: hops)
        case "resolved":
            event = .resolved(p["addresses"] as? [String] ?? [])
        case "bridges.lines":
            event = .bridgeLines(p["lines"] as? [String] ?? [])
        case "error":
            event = .error(code: p["code"] as? String ?? "", message: p["message"] as? String ?? "")
        default:
            event = .other(type)
        }
        return HelperMessage(id: id, event: event)
    }
}
