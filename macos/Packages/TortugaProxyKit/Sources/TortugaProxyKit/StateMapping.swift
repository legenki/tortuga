import Foundation
import TortugaKit

/// The helper's events in the UI's terms (`EngineState`).
public enum StateMapping {
    /// Apply a `circuit` event: the trunk (bridge, guard) and the app's middle
    /// and exit. An app's connection count and last activity are kept; a new
    /// app starts with none, at `now`.
    public static func apply(site: String, bridge: String?, hops: [HelperHop], to state: inout EngineState, now: Date) {
        let kind = bridge.flatMap(Self.bridge)
        state.trunk = Trunk(bridge: kind, guardRelay: hops.first { $0.role == "guard" }.map(relay))
        guard let middle = hops.first(where: { $0.role == "middle" }).map(relay),
              let exit = hops.last(where: { $0.role == "exit" }).map(relay) else { return }
        if let i = state.apps.firstIndex(where: { $0.app.id == site }) {
            state.apps[i].middle = middle
            state.apps[i].exit = exit
        } else {
            state.apps.append(AppRoute(app: AppID(site), middle: middle, exit: exit, connections: 0, lastActive: now))
        }
    }

    public static func status(phase: String, percent: Int, blocked: String?, bridge: BridgeKind?) -> Status {
        if phase == "ready" { return .on }
        let progress = Double(percent) / 100
        if let blocked { return .starting(step: blocked, progress: progress) }
        let step = switch phase {
        case "bridge": bridge == nil ? "Reaching a guard" : "Reaching the bridge"
        default: "Loading the network"
        }
        return .starting(step: step, progress: progress)
    }

    /// The helper's name for a bridge choice.
    public static func helperName(_ kind: BridgeKind?) -> String { kind?.rawValue ?? "none" }

    public static func bridge(_ name: String) -> BridgeKind? { BridgeKind(rawValue: name) }

    static func relay(_ hop: HelperHop) -> Relay {
        Relay(nickname: String(hop.id.prefix(8)), country: hop.country ?? "??", address: hop.addr.map(host) ?? "hidden")
    }

    /// "1.2.3.4:443" → "1.2.3.4"; "[2001:db8::1]:443" → "2001:db8::1".
    static func host(_ addr: String) -> String {
        if addr.hasPrefix("["), let close = addr.firstIndex(of: "]") {
            return String(addr[addr.index(after: addr.startIndex)..<close])
        }
        if let colon = addr.lastIndex(of: ":") { return String(addr[..<colon]) }
        return addr
    }
}
