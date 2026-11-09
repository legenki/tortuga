import Testing
import TortugaKit
@testable import TortugaUI

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}

@MainActor @Suite struct AppModelTests {
    @Test func followsTheEngine() async throws {
        let model = AppModel(engine: DemoEngine(scenario: .normal))
        await model.perform(.mode) { try await $0.setMode(.tor) }
        try await waitUntil { model.state.mode == .tor }
        #expect(model.errors.isEmpty)
    }

    @Test func errorsLandOnTheirControlAndClearOnSuccess() async {
        let model = AppModel(engine: DemoEngine())
        await model.perform(.circuit) { try await $0.newCircuit(for: nil) }
        #expect(model.errors[.circuit] == "Tor isn't on")
        await model.perform(.circuit) { _ in }
        #expect(model.errors[.circuit] == nil)
    }

    @Test func replacingTheEngineStartsOver() async throws {
        let model = AppModel(engine: DemoEngine())
        await model.perform(.mode) { try await $0.setMode(.tor) }
        try await waitUntil { model.state.mode == .tor }
        model.replace(engine: DemoEngine(scenario: .empty))
        try await waitUntil { model.state.mode == .direct }
    }
}

@Test func statusTexts() {
    #expect(Status.on.text(bridge: .snowflake) == "Tor on via Snowflake")
    #expect(Status.on.text(bridge: nil) == "Tor on")
    #expect(Status.off.text(bridge: nil) == "Direct — not using Tor")
    #expect(Status.starting(step: "Building circuits", progress: 0.45).text(bridge: nil) == "Connecting… 45% · Building circuits")
    #expect(Status.blocked(reason: "Tor stopped").text(bridge: nil) == "Tor stopped — traffic is blocked")
    #expect(Status.failed(reason: "Snowflake can't reach its broker").text(bridge: .snowflake) == "Snowflake can't reach its broker")
}
