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
