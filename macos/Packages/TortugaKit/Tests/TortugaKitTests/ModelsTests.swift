import Testing
@testable import TortugaKit

@Test func flagFromCountryCode() {
    #expect(Flag.emoji("de") == "🇩🇪")
    #expect(Flag.emoji("NL") == "🇳🇱")
    #expect(Flag.emoji("XYZ") == "🏳️")
    #expect(Flag.emoji("1A") == "🏳️")
}

@Test func appsAreTheSameByIdentifier() {
    #expect(AppID("com.apple.Safari", name: "Safari") == AppID("com.apple.Safari"))
    #expect(Set([AppID("a", path: "/x"), AppID("a")]).count == 1)
}

@Test func bridgeKinds() {
    #expect(BridgeKind.snowflake.needsLines == false)
    #expect(BridgeKind.obfs4.needsLines)
    #expect(BridgeKind.webtunnel.title == "WebTunnel")
    #expect(BridgeSettings().saved(.obfs4).isEmpty)
}

@Test func initialState() {
    let s = EngineState.initial
    #expect(s.mode == .direct)
    #expect(s.status == .off)
    #expect(s.apps.isEmpty)
}
