import Foundation
import Testing
@testable import TortugaKit

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func makeEngine(_ scenario: Scenario = .normal) -> DemoEngine {
    DemoEngine(scenario: scenario, seed: 1, start: t0)
}

@Suite struct DemoEngineBasics {
    @Test func startsOffWithSnowflakeSelected() async {
        let s = await makeEngine().current
        #expect(s.mode == .direct)
        #expect(s.status == .off)
        #expect(s.bridges.selected == .snowflake)
        #expect(s.exceptions == [DemoData.mail])
        #expect(s.downloads.count == 2)
    }

    @Test func streamStartsWithTheCurrentState() async throws {
        let engine = makeEngine()
        var states = await engine.states().makeAsyncIterator()
        #expect(await states.next()?.status == .off)
        try await engine.setMode(.tor)
        #expect(await states.next()?.mode == .tor)
    }

    @Test func torBootstrapsThenAppsArrive() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(2))
        #expect(await engine.current.status == .starting(step: "Loading the network", progress: 0.5))
        await engine.advance(by: .seconds(2))
        #expect(await engine.current.status == .on)
        #expect(await engine.current.trunk.bridge == .snowflake)
        #expect(await engine.current.trunk.guardRelay != nil)
        await engine.advance(by: .seconds(1))
        #expect(await engine.current.apps.map(\.app.id) == ["com.apple.Safari"])
        await engine.advance(by: .seconds(5))
        #expect(await engine.current.apps.count == 4)
    }

    @Test func directStopsEverything() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(10))
        try await engine.setMode(.direct)
        let s = await engine.current
        #expect(s.status == .off)
        #expect(s.apps.isEmpty)
        #expect(s.trunk == Trunk())
    }
}
