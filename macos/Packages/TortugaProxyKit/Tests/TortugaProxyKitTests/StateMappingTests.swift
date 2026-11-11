import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func hop(_ role: String, _ id: String, _ addr: String?, _ country: String?) -> HelperHop {
    HelperHop(role: role, id: id, addr: addr, country: country)
}

@Test func aCircuitWithAGuardFillsTheTrunkAndTheApp() {
    var state = EngineState()
    StateMapping.apply(site: "com.apple.Safari", bridge: nil, hops: [
        hop("guard", "AAAAAAAAAAAA", "1.1.1.1:443", "DE"),
        hop("middle", "BBBBBBBBBBBB", "2.2.2.2:9001", "NL"),
        hop("exit", "CCCCCCCCCCCC", "[2001:db8::1]:443", "SE"),
    ], to: &state, now: t0)
    #expect(state.trunk == Trunk(bridge: nil, guardRelay: Relay(nickname: "AAAAAAAA", country: "DE", address: "1.1.1.1")))
    #expect(state.apps == [AppRoute(app: AppID("com.apple.Safari"),
                                    middle: Relay(nickname: "BBBBBBBB", country: "NL", address: "2.2.2.2"),
                                    exit: Relay(nickname: "CCCCCCCC", country: "SE", address: "2001:db8::1"),
                                    connections: 0, lastActive: t0)])
}

@Test func aBridgeHasNoSeparateGuard() {
    var state = EngineState()
    StateMapping.apply(site: "a", bridge: "snowflake", hops: [
        hop("bridge", "AAAAAAAA", nil, nil), hop("middle", "BBBBBBBB", "2.2.2.2:1", "NL"), hop("exit", "CCCCCCCC", "3.3.3.3:1", "SE"),
    ], to: &state, now: t0)
    #expect(state.trunk == Trunk(bridge: .snowflake, guardRelay: nil))
}

@Test func aNewCircuitKeepsTheAppsActivity() {
    var state = EngineState()
    state.apps = [AppRoute(app: AppID("a"), middle: Relay(nickname: "m", country: "PL", address: "9.9.9.9"),
                           exit: Relay(nickname: "e", country: "FI", address: "8.8.8.8"), connections: 3, lastActive: t0)]
    StateMapping.apply(site: "a", bridge: nil, hops: [
        hop("guard", "G", "1.1.1.1:1", "DE"), hop("middle", "M2", "2.2.2.2:1", "NL"), hop("exit", "E2", "3.3.3.3:1", "SE"),
    ], to: &state, now: t0.addingTimeInterval(60))
    #expect(state.apps.count == 1)
    #expect(state.apps[0].exit.address == "3.3.3.3")
    #expect(state.apps[0].connections == 3)
    #expect(state.apps[0].lastActive == t0)
}

@Test func statusFromBootstrap() {
    #expect(StateMapping.status(phase: "bridge", percent: 10, blocked: nil, bridge: .snowflake)
            == .starting(step: "Reaching the bridge", progress: 0.1))
    #expect(StateMapping.status(phase: "bridge", percent: 10, blocked: nil, bridge: nil)
            == .starting(step: "Reaching a guard", progress: 0.1))
    #expect(StateMapping.status(phase: "directory", percent: 55, blocked: nil, bridge: nil)
            == .starting(step: "Loading the network", progress: 0.55))
    #expect(StateMapping.status(phase: "directory", percent: 55, blocked: "Can't reach the bridge", bridge: .obfs4)
            == .starting(step: "Can't reach the bridge", progress: 0.55))
    #expect(StateMapping.status(phase: "ready", percent: 100, blocked: nil, bridge: nil) == .on)
}

@Test func bridgeKindsByTheHelpersNames() {
    #expect(StateMapping.helperName(nil) == "none")
    #expect(StateMapping.helperName(.webtunnel) == "webtunnel")
    #expect(StateMapping.bridge("snowflake") == .snowflake)
    #expect(StateMapping.bridge("none") == nil)
}
