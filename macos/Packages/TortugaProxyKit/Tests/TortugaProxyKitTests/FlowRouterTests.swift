import Foundation
import Testing
@testable import TortugaProxyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test(arguments: ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.3.4",
                  "224.0.0.251", "255.255.255.255", "0.0.0.0", "::1", "fe80::1", "fd12::1", "ff02::fb", "::ffff:192.168.1.1"])
func localAddresses(_ ip: String) {
    #expect(LocalAddress.isLocal(ip))
}

@Test(arguments: ["8.8.8.8", "172.32.0.1", "93.184.215.14", "2001:4860:4860::8888", "::ffff:8.8.8.8", "not an ip", "example.com"])
func publicAddresses(_ ip: String) {
    #expect(!LocalAddress.isLocal(ip))
}

private func flow(app: String = "com.apple.Safari", host: String? = "example.com", ip: String = "93.184.215.14",
                  port: Int = 443, udp: Bool = false, ancestors: @escaping @Sendable () -> [String] = { [] }) -> FlowInfo {
    FlowInfo(app: app, remoteHost: host, remoteIP: ip, port: port, isUDP: udp, ancestors: ancestors)
}

private let notAsked: @Sendable () -> [String] = {
    Issue.record("ancestors asked for")
    return []
}

private let ready = RouterState(torReady: true, torApps: ["com.apple.Safari", "com.google.Chrome"],
                                own: ["org.tortuga.helper"])

@Test func aHelperUsesItsAppsCircuit() {
    #expect(FlowRouter.decide(flow(app: "com.google.Chrome.helper"), ready, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.google.Chrome"))
}

@Test func byNameThroughTorIsolatedByApp() {
    #expect(FlowRouter.decide(flow(), ready, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.apple.Safari"))
}

@Test func byIPUsesTheNameFromDNS() {
    let names = NameCache()
    names.record(ip: "93.184.215.14", name: "example.com", now: t0)
    #expect(FlowRouter.decide(flow(host: nil), ready, names: names, now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.apple.Safari"))
}

@Test func byIPWithoutANameKeepsTheIP() {
    #expect(FlowRouter.decide(flow(host: nil), ready, names: NameCache(), now: t0)
            == .tor(host: "93.184.215.14", port: 443, isolation: "com.apple.Safari"))
}

@Test func unlistedAppsGoDirect() {
    #expect(FlowRouter.decide(flow(app: "com.apple.mail"), ready, names: NameCache(), now: t0) == .unlisted)
}

@Test func unlistedUDPGoesDirect() {
    #expect(FlowRouter.decide(flow(app: "com.apple.mail", udp: true), ready, names: NameCache(), now: t0) == .unlisted)
    let notReady = RouterState(torReady: false, torApps: ["com.apple.Safari"], own: [])
    #expect(FlowRouter.decide(flow(app: "com.apple.mail", udp: true), notReady, names: NameCache(), now: t0) == .unlisted)
}

@Test func ownAndLocalGoDirect() {
    #expect(FlowRouter.decide(flow(app: "org.tortuga.helper"), ready, names: NameCache(), now: t0) == .direct)
    #expect(FlowRouter.decide(flow(host: "printer.local", ip: "192.168.1.20"), ready, names: NameCache(), now: t0) == .direct)
}

@Test func onlyListedAppsWaitForTor() {
    let notReady = RouterState(torReady: false, torApps: ["com.apple.Safari"], own: [])
    #expect(FlowRouter.decide(flow(), notReady, names: NameCache(), now: t0) == .refuse)
    #expect(FlowRouter.decide(flow(app: "com.apple.mail"), notReady, names: NameCache(), now: t0) == .unlisted)
    #expect(FlowRouter.decide(flow(host: "router.lan", ip: "192.168.1.1"), notReady, names: NameCache(), now: t0) == .direct)
}

@Test func nothingButOwnAndLocalGoesOutUntilTheListArrives() {
    let unconfigured = RouterState(torReady: false, torApps: nil, own: ["org.tortuga.helper"])
    #expect(FlowRouter.decide(flow(), unconfigured, names: NameCache(), now: t0) == .refuse)
    #expect(FlowRouter.decide(flow(app: "com.apple.mail"), unconfigured, names: NameCache(), now: t0) == .refuse)
    #expect(FlowRouter.decide(flow(app: "org.tortuga.helper"), unconfigured, names: NameCache(), now: t0) == .direct)
    #expect(FlowRouter.decide(flow(host: "printer.local", ip: "192.168.1.20"), unconfigured, names: NameCache(), now: t0) == .direct)
}

@Test func udpFromAListedAppIsRefused() {
    #expect(FlowRouter.decide(flow(udp: true), ready, names: NameCache(), now: t0) == .refuse)
}

@Test func namesExpireAndTheCacheStaysSmall() {
    let names = NameCache(capacity: 2)
    names.record(ip: "1.1.1.1", name: "a", ttl: 10, now: t0)
    #expect(names.name(for: "1.1.1.1", now: t0.addingTimeInterval(9)) == "a")
    #expect(names.name(for: "1.1.1.1", now: t0.addingTimeInterval(11)) == nil)
    names.record(ip: "2.2.2.2", name: "b", now: t0)
    names.record(ip: "3.3.3.3", name: "c", now: t0)
    names.record(ip: "4.4.4.4", name: "d", now: t0)
    #expect(names.count == 2)
    #expect(names.name(for: "4.4.4.4", now: t0) == "d")
}

private let withFirefox = RouterState(torReady: true, torApps: ["org.mozilla.firefox"], own: ["org.tortuga.helper"])
private let firefoxLineage: @Sendable () -> [String] = { ["org.mozilla.firefox", "com.apple.launchd"] }

@Test func aChildsUDPIsRefusedLikeItsApps() {
    // Firefox's WebRTC runs in org.mozilla.plugincontainer: its UDP went out directly.
    #expect(FlowRouter.decide(flow(app: "org.mozilla.plugincontainer", udp: true, ancestors: firefoxLineage),
                              withFirefox, names: NameCache(), now: t0) == .refuse)
}

@Test func aChildsTCPUsesItsAppsCircuit() {
    #expect(FlowRouter.decide(flow(app: "org.mozilla.plugincontainer", ancestors: firefoxLineage),
                              withFirefox, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "org.mozilla.firefox"))
}

@Test func anUnlistedProcessWithUnlistedAncestorsIsUnlisted() {
    #expect(FlowRouter.decide(flow(app: "com.apple.curl", ancestors: { ["com.apple.zsh", "com.apple.Terminal"] }),
                              withFirefox, names: NameCache(), now: t0) == .unlisted)
}

@Test func ancestorsAreAskedForOnlyWhenNeeded() {
    #expect(FlowRouter.decide(flow(ancestors: notAsked), ready, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.apple.Safari"))
    #expect(FlowRouter.decide(flow(app: "com.google.Chrome.helper", ancestors: notAsked), ready, names: NameCache(), now: t0)
            == .tor(host: "example.com", port: 443, isolation: "com.google.Chrome"))
    #expect(FlowRouter.decide(flow(app: "org.tortuga.helper", ancestors: notAsked), ready, names: NameCache(), now: t0) == .direct)
    #expect(FlowRouter.decide(flow(host: "printer.local", ip: "192.168.1.20", ancestors: notAsked), ready, names: NameCache(), now: t0)
            == .direct)
}

@Test func flowsCompareWithoutTheirAncestors() {
    #expect(flow(ancestors: firefoxLineage) == flow())
    #expect(flow(app: "com.apple.mail") != flow())
}
