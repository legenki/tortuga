import Testing
@testable import TortugaProxyKit

private let list: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
private let own: Set<String> = ["tortuga-helper", "lyrebird"]

@Test func listedAppsAskTor() {
    #expect(DNSRoute.upstream(app: "com.apple.Safari", torApps: list, own: own, system: "192.168.1.1") == nil)
    #expect(DNSRoute.upstream(app: "com.google.Chrome.helper", torApps: list, own: own, system: "192.168.1.1") == nil)
}

@Test func unlistedAndOwnAskTheSystem() {
    #expect(DNSRoute.upstream(app: "com.apple.mail", torApps: list, own: own, system: "192.168.1.1") == "192.168.1.1")
    #expect(DNSRoute.upstream(app: "lyrebird", torApps: list, own: own, system: "192.168.1.1") == "192.168.1.1")
}

@Test func untilTheListArrivesOnlyOwnAskTheSystem() {
    #expect(DNSRoute.upstream(app: "com.apple.mail", torApps: nil, own: own, system: "192.168.1.1") == nil)
    #expect(DNSRoute.upstream(app: "com.apple.Safari", torApps: nil, own: own, system: "192.168.1.1") == nil)
    #expect(DNSRoute.upstream(app: "tortuga-helper", torApps: nil, own: own, system: "192.168.1.1") == "192.168.1.1")
}

@Test func aListedAppsChildAsksTor() {
    let firefox: Set<String> = ["org.mozilla.firefox"]
    #expect(DNSRoute.upstream(app: "org.mozilla.plugincontainer", ancestors: { ["org.mozilla.firefox", "com.apple.launchd"] },
                              torApps: firefox, own: own, system: "192.168.1.1") == nil)
    #expect(DNSRoute.upstream(app: "com.apple.curl", ancestors: { ["com.apple.zsh", "com.apple.Terminal"] },
                              torApps: firefox, own: own, system: "192.168.1.1") == "192.168.1.1")
}

@Test func dnsAsksForAncestorsOnlyWhenNeeded() {
    let upstream = DNSRoute.upstream(app: "com.apple.Safari", ancestors: {
        Issue.record("ancestors asked for a listed app")
        return []
    }, torApps: list, own: own, system: "192.168.1.1")
    #expect(upstream == nil)
    #expect(DNSRoute.upstream(app: "lyrebird", ancestors: {
        Issue.record("ancestors asked for our own program")
        return []
    }, torApps: list, own: own, system: "192.168.1.1") == "192.168.1.1")
}
