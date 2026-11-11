import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

let sampleConfig = ProxyConfiguration(bridge: .snowflake, lines: [.obfs4: ["Bridge obfs4 x"]],
                                      exceptions: ["com.apple.mail"], helperPath: "/A/helper", ptDir: "/A/pt")

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

@Test func theRouteTableHandsOutWhatWasPut() {
    let table = RouteTable()
    #expect(table.snapshot().socksPort == nil)
    #expect(table.snapshot().state.torReady == false)
    #expect(table.snapshot().state.own == ProxyCore.ownIDs)
    table.update(state: RouterState(torReady: true, exceptions: ["x"], own: ProxyCore.ownIDs), socksPort: 9150)
    #expect(table.snapshot().socksPort == 9150)
    #expect(table.snapshot().state.exceptions == ["x"])
}
