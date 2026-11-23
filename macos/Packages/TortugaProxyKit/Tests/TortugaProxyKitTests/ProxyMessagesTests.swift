import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

let sampleConfig = ProxyConfiguration(bridge: .snowflake, lines: [.obfs4: ["Bridge obfs4 x"]],
                                      torApps: ["com.apple.Safari"], helperPath: "/A/helper", ptDir: "/A/pt")

@Test func configurationTravelsInTheProviderConfiguration() throws {
    let dictionary = try sampleConfig.providerConfiguration()
    #expect(ProxyConfiguration(providerConfiguration: dictionary) == sampleConfig)
    #expect(ProxyConfiguration(providerConfiguration: nil) == nil)
    #expect(ProxyConfiguration(providerConfiguration: ["configuration": Data("x".utf8)]) == nil)
}

@Test func commandsRepliesAndStatesRoundTrip() {
    for command in [ExtensionCommand.configure(sampleConfig), .restart, .newCircuit(app: "a"), .newCircuit(app: nil),
                    .fetchBridgeLines(.obfs4)] {
        #expect(Wire.decode(ExtensionCommand.self, Wire.encode(command)) == command)
    }
    for reply in [ExtensionReply.ok, .lines(["l"]), .failure("no")] {
        #expect(Wire.decode(ExtensionReply.self, Wire.encode(reply)) == reply)
    }
    let state = ExtensionState(status: .blocked(reason: "Tor stopped"), trunk: Trunk(bridge: .snowflake, guardRelay: nil), apps: [])
    #expect(Wire.decode(ExtensionState.self, Wire.encode(state)) == state)
    #expect(Wire.decode(ExtensionReply.self, Data("garbage".utf8)) == nil)
}

@Test func aStateWithAppsGoingDirectRoundTrips() {
    let state = ExtensionState(status: .on, trunk: Trunk(), apps: [], seenDirect: ["com.apple.mail", "com.apple.Music"])
    #expect(Wire.decode(ExtensionState.self, Wire.encode(state)) == state)
}

@Test func aStateFromAnOlderExtensionDecodesWithoutSeenDirect() throws {
    let state = ExtensionState(status: .on, trunk: Trunk(bridge: .snowflake, guardRelay: nil), apps: [], seenDirect: ["x"])
    var json = try #require(JSONSerialization.jsonObject(with: Wire.encode(state)) as? [String: Any])
    json["seenDirect"] = nil
    let decoded = try #require(Wire.decode(ExtensionState.self, try JSONSerialization.data(withJSONObject: json)))
    #expect(decoded.seenDirect == [])
    #expect(decoded.status == .on)
    #expect(decoded.trunk == state.trunk)
}

@Test func theRouteTableHandsOutWhatWasPut() {
    let table = RouteTable()
    #expect(table.snapshot().socksPort == nil)
    #expect(table.snapshot().state.torReady == false)
    #expect(table.snapshot().state.own == ProxyCore.ownIDs)
    #expect(table.snapshot().state.torApps == nil)
    table.update(state: RouterState(torReady: true, torApps: ["x"], own: ProxyCore.ownIDs), socksPort: 9150)
    #expect(table.snapshot().socksPort == 9150)
    #expect(table.snapshot().state.torApps == ["x"])
}
