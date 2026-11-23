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

    @Test func removingAnAppClearsItsSelectionAndHover() async {
        let model = AppModel(engine: DemoEngine())
        let app = AppID("com.apple.Safari")
        model.expandedApp = app.id
        model.hoveredApp = app.id
        await model.removeTorApp(app)
        #expect(model.expandedApp == nil)
        #expect(model.hoveredApp == nil)
    }
}
