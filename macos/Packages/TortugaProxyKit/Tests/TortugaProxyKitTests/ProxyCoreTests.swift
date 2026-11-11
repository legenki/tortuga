import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

private func onCore() async throws -> (ProxyCore, FakeLauncher, Task<Void, Never>) {
    let launcher = FakeLauncher()
    let core = ProxyCore(launcher: launcher, retryDelay: .zero)
    await core.configure(sampleConfig)
    let starting = Task { await core.start() }
    try await eventually { launcher.transports.count == 1 }
    let server = serve(launcher.transports[0], ["hello": helloAnswer, "tor.start": readyAnswer, "tor.resolve": resolvedAnswer])
    await starting.value
    try await eventually { await core.current.status == .on }
    return (core, launcher, server)
}

@Suite struct ProxyCoreTests {
    @Test func noTrafficUntilACircuitWorks() async throws {
        let launcher = FakeLauncher()
        let core = ProxyCore(launcher: launcher, retryDelay: .zero)
        await core.configure(sampleConfig)
        let starting = Task { await core.start() }
        try await eventually { launcher.transports.count == 1 }
        let fake = launcher.transports[0]
        let server = serve(fake, ["hello": helloAnswer, "tor.start": readyAnswer])
        await starting.value
        // Ready from Arti's cache, but no circuit has worked yet.
        #expect(await core.current.status == .starting(step: "Building circuits", progress: 0.95))
        #expect(core.routes.snapshot().state.torReady == false)
        #expect(core.routes.snapshot().socksPort == 40000)
        try await eventually { fake.requests.contains { $0["type"] as? String == "tor.resolve" } }
        let resolver = serve(fake, ["tor.resolve": resolvedAnswer])
        try await eventually { await core.current.status == .on }
        #expect(core.routes.snapshot().state.torReady)
        server.cancel()
        resolver.cancel()
    }

    @Test func startsTheHelperWithTheBridgeAndGoesOn() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        #expect(await core.current.status == .on)
        let snapshot = core.routes.snapshot()
        #expect(snapshot.state.torReady)
        #expect(snapshot.socksPort == 40000)
        #expect(snapshot.state.exceptions == ["com.apple.mail"])
        let start = try #require(launcher.transports[0].requests.first { $0["type"] as? String == "tor.start" })
        let bridge = (start["payload"] as? [String: Any])?["bridge"] as? [String: Any]
        #expect(bridge?["kind"] as? String == "snowflake")
    }

    @Test func bootstrapProgressShowsUntilReady() async throws {
        let launcher = FakeLauncher()
        let core = ProxyCore(launcher: launcher, retryDelay: .zero)
        await core.configure(sampleConfig)
        let starting = Task { await core.start() }
        try await eventually { launcher.transports.count == 1 }
        let fake = launcher.transports[0]
        let server = serve(fake, ["hello": helloAnswer])
        fake.send(#"{"type":"tor.status","payload":{"phase":"directory","percent":40,"blocked":null}}"#)
        try await eventually { await core.current.status == .starting(step: "Loading the network", progress: 0.4) }
        #expect(core.routes.snapshot().state.torReady == false)
        server.cancel()
        await core.stop()
        _ = await starting.value
    }

    @Test func circuitsBecomeRoutesAndFlowsCount() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        await core.flowOpened(app: "com.apple.Safari")
        launcher.transports[0].send(#"{"type":"circuit","payload":{"site":"com.apple.Safari","bridge":"snowflake","hops":[{"role":"bridge","id":"B","addr":null,"country":null},{"role":"middle","id":"M","addr":"2.2.2.2:1","country":"NL"},{"role":"exit","id":"E","addr":"3.3.3.3:1","country":"SE"}]}}"#)
        try await eventually { await core.current.apps.count == 1 }
        let route = await core.current.apps[0]
        #expect(route.app.id == "com.apple.Safari")
        #expect(route.exit.country == "SE")
        #expect(route.connections == 1)
        #expect(await core.current.trunk.bridge == .snowflake)
        await core.flowOpened(app: "com.apple.Safari")
        await core.flowClosed(app: "com.apple.Safari")
        #expect(await core.current.apps[0].connections == 1)
    }

    @Test func aDeadHelperBlocksThenComesBack() async throws {
        let (core, launcher, server) = try await onCore()
        server.cancel()
        launcher.transports[0].close()
        try await eventually { launcher.transports.count == 2 }
        #expect(core.routes.snapshot().state.torReady == false)
        let second = serve(launcher.transports[1], ["hello": helloAnswer, "tor.start": readyAnswer, "tor.resolve": resolvedAnswer])
        defer { second.cancel() }
        try await eventually { await core.current.status == .on }
    }

    @Test func noHelperMeansMoveToApplications() async throws {
        let launcher = FakeLauncher()
        launcher.fail()
        let core = ProxyCore(launcher: launcher, retryDelay: .zero)
        await core.configure(sampleConfig)
        await core.start()
        #expect(await core.current.status == .failed(reason: "Tortuga isn't in /Applications: move it there, then Restart"))
    }

    @Test func commandsNeedTor() async {
        let core = ProxyCore(launcher: FakeLauncher(), retryDelay: .zero)
        await #expect(throws: EngineError("Tor isn't on")) { try await core.newCircuit(app: nil) }
        await #expect(throws: EngineError("Tor isn't on")) { try await core.resolve("example.com") }
    }

    @Test func resolveAndNewCircuitGoToTheHelper() async throws {
        let (core, launcher, server) = try await onCore()
        server.cancel()
        let fake = launcher.transports[0]
        let more = serve(fake, ["tor.resolve": { #"{"id":\#($0),"type":"resolved","payload":{"addresses":["93.184.215.14"]}}"# },
                                "tor.newCircuit": { #"{"id":\#($0),"type":"ok"}"# }])
        defer { more.cancel() }
        #expect(try await core.resolve("example.com") == ["93.184.215.14"])
        try await core.newCircuit(app: "com.apple.Safari")
        #expect(fake.requests.contains { ($0["payload"] as? [String: Any])?["site"] as? String == "com.apple.Safari" })
    }

    @Test func stoppingEndsTheHelper() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        await core.stop()
        #expect(await core.current == .idle)
        #expect(launcher.transports[0].terminated)
        #expect(core.routes.snapshot().socksPort == nil)
    }

    @Test func aNewBridgeRestartsTheHelper() async throws {
        let (core, launcher, server) = try await onCore()
        defer { server.cancel() }
        var changed = sampleConfig
        changed.bridge = nil
        let configuring = Task { await core.configure(changed) }
        try await eventually { launcher.transports.count == 2 }
        let second = serve(launcher.transports[1], ["hello": helloAnswer, "tor.start": readyAnswer, "tor.resolve": resolvedAnswer])
        defer { second.cancel() }
        await configuring.value
        let start = try #require(launcher.transports[1].requests.first { $0["type"] as? String == "tor.start" })
        #expect(((start["payload"] as? [String: Any])?["bridge"] as? [String: Any])?["kind"] as? String == "none")
    }
}
