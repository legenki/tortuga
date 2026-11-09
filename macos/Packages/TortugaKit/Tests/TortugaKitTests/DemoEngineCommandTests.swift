import Foundation
import Testing
@testable import TortugaKit

private let safari = AppID("com.apple.Safari")

@Suite struct DemoEngineCommands {
    @Test func newCircuitChangesTheExitAfterASecond() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))   // on
        await engine.advance(by: .seconds(1))   // Safari arrives
        let before = try #require(await engine.current.apps.first { $0.app == safari }).exit
        try await engine.newCircuit(for: safari)
        await engine.advance(by: .milliseconds(900))
        #expect(await engine.current.apps.first { $0.app == safari }?.exit == before)
        await engine.advance(by: .milliseconds(100))
        #expect(await engine.current.apps.first { $0.app == safari }?.exit != before)
    }

    @Test func newCircuitNeedsTor() async {
        await #expect(throws: EngineError("Tor isn't on")) { try await makeEngine().newCircuit(for: nil) }
    }

    @Test func restartNeedsTor() async {
        await #expect(throws: EngineError("Switch to Tor first")) { try await makeEngine().restart() }
    }

    @Test func torDiesOnceAndRestartBringsItBack() async throws {
        let engine = makeEngine(.torDies)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.status == .on)
        await engine.advance(by: .seconds(5))
        #expect(await engine.current.status == .blocked(reason: "Tor stopped"))
        try await engine.restart()
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.status == .on)
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.status == .on)
    }

    @Test func slowBootstrapTakesThirtySeconds() async throws {
        let engine = makeEngine(.slowBootstrap)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(29))
        #expect(await engine.current.status != .on)
        await engine.advance(by: .seconds(1))
        #expect(await engine.current.status == .on)
    }

    @Test func snowflakeFailsInBridgeFailsButObfs4Works() async throws {
        let engine = makeEngine(.bridgeFails)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(6))
        #expect(await engine.current.status == .failed(reason: "Snowflake can't reach its broker"))
        try await engine.saveBridgeLines(DemoData.obfs4Lines, for: .obfs4)
        try await engine.selectBridge(.obfs4)
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.status == .on)
        #expect(await engine.current.trunk.bridge == .obfs4)
    }

    @Test func obfs4WithoutLinesFails() async throws {
        let engine = makeEngine()
        try await engine.selectBridge(.obfs4)
        try await engine.setMode(.tor)
        #expect(await engine.current.status == .failed(reason: "Save obfs4 lines first, or pick another bridge"))
    }

    @Test func noBridgeConnectsDirectlyToAGuard() async throws {
        let engine = makeEngine()
        try await engine.selectBridge(nil)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))
        #expect(await engine.current.trunk.bridge == nil)
        #expect(await engine.current.status == .on)
    }

    @Test func savingBadLinesThrowsTheFirstProblem() async {
        let engine = makeEngine()
        await #expect(throws: EngineError("Line 1: no 40-character fingerprint after the address")) {
            try await engine.saveBridgeLines(["obfs4 192.0.2.1:443 nope"], for: .obfs4)
        }
    }

    @Test func savedLinesStartWithBridge() async throws {
        let engine = makeEngine()
        try await engine.saveBridgeLines(["obfs4 192.0.2.1:443 \(String(repeating: "B", count: 40))"], for: .obfs4)
        #expect(await engine.current.bridges.saved(.obfs4).first?.hasPrefix("Bridge obfs4 ") == true)
    }

    @Test func fetchingObfs4LinesTakesHalfASecond() async throws {
        let engine = makeEngine()
        let fetch = Task { try await engine.fetchBridgeLines(.obfs4) }
        while await engine.pendingFetches == 0 { await Task.yield() }
        await engine.advance(by: .milliseconds(500))
        #expect(try await fetch.value.count == 7)
    }

    @Test func webTunnelLinesAreNotNeededHere() async throws {
        let engine = makeEngine()
        let fetch = Task { try await engine.fetchBridgeLines(.webtunnel) }
        while await engine.pendingFetches == 0 { await Task.yield() }
        await engine.advance(by: .milliseconds(500))
        await #expect(throws: EngineError("bridges.torproject.org says none are needed here")) { try await fetch.value }
    }

    @Test func exceptingAnAppDropsItsRouteAndKeepsItOut() async throws {
        let engine = makeEngine()
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))   // on
        await engine.advance(by: .seconds(1))   // Safari arrives
        try await engine.addException(safari)
        #expect(await engine.current.apps.isEmpty)
        #expect(await engine.current.exceptions.contains(safari))
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.apps.map(\.app.id) == ["ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap", "com.apple.Music"])
        try await engine.removeException(safari)
        #expect(await !engine.current.exceptions.contains(safari))
    }

    @Test func manyAppsShowsThirtyHalfOfThemIdle() async throws {
        let engine = makeEngine(.manyApps)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(4))
        let s = await engine.current
        #expect(s.apps.count == 30)
        let list = RouteList(apps: s.apps, exceptions: s.exceptions, now: t0.addingTimeInterval(4))
        #expect(list.active.count == 15)
        #expect(list.idle.count == 15)
    }

    @Test func emptyHasNoApps() async throws {
        let engine = makeEngine(.empty)
        try await engine.setMode(.tor)
        await engine.advance(by: .seconds(20))
        #expect(await engine.current.status == .on)
        #expect(await engine.current.apps.isEmpty)
    }
}

@Suite struct DemoEngineDownloads {
    @Test func downloadsGrowAndPauseStopsThem() async throws {
        let engine = makeEngine()
        let first = await engine.current.downloads[0]
        await engine.advance(by: .seconds(10))
        let grown = await engine.current.downloads[0]
        #expect(grown.done > first.done)
        try await engine.pauseDownload(first.id)
        await engine.advance(by: .seconds(10))
        #expect(await engine.current.downloads[0].done == grown.done)
        #expect(await engine.current.downloads[0].state == .paused)
        try await engine.resumeDownload(first.id)
        #expect(await engine.current.downloads[0].state == .downloading)
    }

    @Test func finishedDownloadsShareUntilRatioOne() async throws {
        let engine = makeEngine(.empty)
        try await engine.addDownload(.magnet("magnet:?xt=urn:btih:abc&dn=small.iso"))
        let id = await engine.current.downloads[0].id
        // 1 GiB at 3 MB/s takes about 358 s; sharing it back at 1.5 MB/s about 716 s.
        await engine.advance(by: .seconds(360))
        #expect(await engine.current.downloads[0].state == .sharing)
        await engine.advance(by: .seconds(720))
        #expect(await engine.current.downloads[0].state == .done)
        try await engine.removeDownload(id)
        #expect(await engine.current.downloads.isEmpty)
    }

    @Test func addingTakesTheMagnetsNameAndRefusesOtherFiles() async throws {
        let engine = makeEngine(.empty)
        try await engine.addDownload(.magnet("magnet:?xt=urn:btih:abc&dn=ubuntu.iso"))
        #expect(await engine.current.downloads.last?.name == "ubuntu.iso")
        try await engine.addDownload(.file(URL(fileURLWithPath: "/tmp/debian.torrent")))
        #expect(await engine.current.downloads.last?.name == "debian")
        await #expect(throws: EngineError("Not a .torrent file")) {
            try await engine.addDownload(.file(URL(fileURLWithPath: "/tmp/a.zip")))
        }
        await #expect(throws: EngineError("No such download")) { try await engine.removeDownload(UUID()) }
    }
}
