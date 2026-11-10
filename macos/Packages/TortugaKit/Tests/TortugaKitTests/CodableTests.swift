import Foundation
import Testing
@testable import TortugaKit

@Test func engineStateRoundTrips() throws {
    var state = EngineState()
    state.mode = .tor
    state.status = .starting(step: "Loading the network", progress: 0.4)
    state.trunk = Trunk(bridge: .snowflake, guardRelay: Relay(nickname: "g", country: "DE", address: "1.1.1.1"))
    state.apps = [AppRoute(app: AppID("com.apple.Safari", name: "Safari"),
                           middle: Relay(nickname: "m", country: "NL", address: "2.2.2.2"),
                           exit: Relay(nickname: "e", country: "SE", address: "3.3.3.3"),
                           connections: 2, lastActive: Date(timeIntervalSince1970: 1_800_000_000))]
    state.bridges = BridgeSettings(selected: .obfs4, lines: [.obfs4: ["Bridge obfs4 x"]])
    state.exceptions = [AppID("com.apple.mail")]
    state.downloadsAvailable = false
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(EngineState.self, from: data) == state)
}

@Test func theAllowMessageIsShared() {
    #expect(Status.allowExtensionReason == "Allow Tortuga's network extension in System Settings")
}
