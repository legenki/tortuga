import Foundation
import Testing
@testable import TortugaUI
import TortugaKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let relay = Relay(nickname: "r", country: "DE", address: "192.0.2.1")

private func state(_ status: Status, apps: Int = 0) -> EngineState {
    var s = EngineState()
    s.status = status
    s.trunk = Trunk(guardRelay: relay)
    s.torApps = (0..<apps).map { AppID("app\($0)") }
    s.apps = (0..<apps).map { AppRoute(app: AppID("app\($0)"), middle: relay, exit: relay, connections: 1, lastActive: now) }
    return s
}

@Test func offOffersTor() {
    let c = StatusPill.Content(state: state(.off), now: now, showsGuard: true)
    #expect(c.title == "Direct" && c.detail == "turn on Tor" && c.turnsOn && c.tone == .off)
}

@Test func startingShowsProgress() {
    let c = StatusPill.Content(state: state(.starting(step: "Building circuits", progress: 0.42)), now: now, showsGuard: true)
    #expect(c.title == "Connecting… 42%" && c.detail == "Building circuits" && c.progress == 0.42 && !c.turnsOn)
}

@Test func onCountsAppsAndNamesTheGuard() {
    let window = StatusPill.Content(state: state(.on, apps: 3), now: now, showsGuard: true)
    #expect(window.title == "Tor on" && window.detail == "3 apps · Guard 🇩🇪 Germany" && !window.turnsOn)
    let menu = StatusPill.Content(state: state(.on, apps: 1), now: now, showsGuard: false)
    #expect(menu.detail == "1 app")
    #expect(StatusPill.Content(state: state(.on), now: now, showsGuard: false).detail == "no traffic yet")
}

@Test func problemsSayWhatHappened() {
    let blocked = StatusPill.Content(state: state(.blocked(reason: "Tor stopped")), now: now, showsGuard: true)
    #expect(blocked.title == "Tor stopped" && blocked.detail == "Tor apps are blocked" && blocked.tone == .problem)
    let failed = StatusPill.Content(state: state(.failed(reason: "Snowflake can't reach its broker")), now: now, showsGuard: true)
    #expect(failed.title == "Snowflake can't reach its broker" && failed.detail.isEmpty && !failed.turnsOn)
}

@Test func theLabelReadsAsOneSentence() {
    let c = StatusPill.Content(state: state(.on, apps: 2), now: now, showsGuard: false)
    #expect(c.label == "Tor on, 2 apps")
}
