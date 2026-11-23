import Foundation
import TortugaKit

/// A flow as the transparent proxy sees it.
public struct FlowInfo: Sendable, Equatable {
    /// The app's code-signing identifier.
    public var app: String
    /// The name the app connected to, when it connected by name.
    public var remoteHost: String?
    public var remoteIP: String
    public var port: Int
    public var isUDP: Bool
    /// The code-signing identifiers of the app's parent, grandparent, … up
    /// the process tree. Asked only when the app itself isn't in the Tor
    /// list: finding them takes system calls. Not part of equality.
    public var ancestors: @Sendable () -> [String]

    public init(app: String, remoteHost: String?, remoteIP: String, port: Int, isUDP: Bool,
                ancestors: @escaping @Sendable () -> [String] = { [] }) {
        self.app = app
        self.remoteHost = remoteHost
        self.remoteIP = remoteIP
        self.port = port
        self.isUDP = isUDP
        self.ancestors = ancestors
    }

    public static func == (a: FlowInfo, b: FlowInfo) -> Bool {
        a.app == b.app && a.remoteHost == b.remoteHost && a.remoteIP == b.remoteIP && a.port == b.port && a.isUDP == b.isUDP
    }
}

/// What the router needs to know besides the flow.
public struct RouterState: Sendable, Equatable {
    public var torReady: Bool
    /// Signing identifiers of the apps that go through Tor; nil until the
    /// app's settings arrive, when nothing but our own and local traffic
    /// goes out.
    public var torApps: Set<String>?
    /// The helper and lyrebird: their traffic must never go through Tor.
    public var own: Set<String>

    public init(torReady: Bool, torApps: Set<String>?, own: Set<String>) {
        self.torReady = torReady
        self.torApps = torApps
        self.own = own
    }
}

public enum FlowDecision: Sendable, Equatable {
    /// Let macOS send it as usual.
    case direct
    /// Let macOS send it as usual: the app isn't in the Tor list.
    case unlisted
    /// Close it: a listed app's flow while Tor isn't ready, or its UDP; or,
    /// until the Tor list arrives, any flow that isn't ours or local.
    case refuse
    /// Through the helper's SOCKS port, isolated by `isolation`.
    case tor(host: String, port: Int, isolation: String)
}

public enum FlowRouter {
    public static func decide(_ flow: FlowInfo, _ state: RouterState, names: NameCache, now: Date = .now) -> FlowDecision {
        if state.own.contains(flow.app) || LocalAddress.isLocal(flow.remoteIP) { return .direct }
        guard let torApps = state.torApps else { return .refuse }
        guard let listed = listedApp(flow.app, ancestors: flow.ancestors, in: torApps) else { return .unlisted }
        if flow.isUDP || !state.torReady { return .refuse }
        let byName = flow.remoteHost.flatMap { $0.isEmpty ? nil : $0 }
        let host = byName ?? names.name(for: flow.remoteIP, now: now) ?? flow.remoteIP
        // The listed ID, not the helper's or child's: an app and its helpers
        // and child processes share a circuit.
        return .tor(host: host, port: flow.port, isolation: listed)
    }

    /// The listed app a process counts as: itself, or else the nearest of its
    /// ancestors that is listed (Firefox for its plugin-container, whose
    /// WebRTC UDP would otherwise leave directly). `ancestors` is called only
    /// when the process itself doesn't match.
    public static func listedApp(_ app: String, ancestors: () -> [String], in torApps: Set<String>) -> String? {
        TorAppMatcher.match(app, in: torApps) ?? TorAppMatcher.match(lineage: ancestors(), in: torApps)
    }
}
