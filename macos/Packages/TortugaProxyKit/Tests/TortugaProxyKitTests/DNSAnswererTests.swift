import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

private func query(_ type: UInt16) -> Data {
    var b: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0] + [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
    return Data(b)
}

private func rcode(_ answer: Data?) -> UInt8? { answer.map { $0[3] & 0x0F } }
private func answers(_ answer: Data?) -> Int? { answer.map { Int($0[6]) << 8 | Int($0[7]) } }

@Test func aQueryIsResolvedThroughTorAndRemembered() async {
    let names = NameCache()
    let answer = await DNSAnswerer.answer(query(DNSType.a), torReady: { true }, names: names) { name in
        #expect(name == "example.com")
        return ["93.184.215.14"]
    }
    #expect(rcode(answer) == 0)
    #expect(answers(answer) == 1)
    #expect(names.name(for: "93.184.215.14") == "example.com")
}

/// Flips to ready after a while, as the core does once a lookup through Tor works.
private final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    func set() { lock.withLock { ready = true } }
    func get() -> Bool { lock.withLock { ready } }
}

// mDNSResponder caches any answer without records for at least 60 s (75 s
// with its grace), whatever SOA comes with it, but caches nothing when no
// answer comes. So a query asked while Tor builds circuits waits for Tor.
@Test func aQueryAskedBeforeTorIsReadyWaitsForTor() async {
    let readiness = Readiness()
    Task {
        try? await Task.sleep(for: .milliseconds(300))
        readiness.set()
    }
    let start = ContinuousClock.now
    let answer = await DNSAnswerer.answer(query(DNSType.a), torReady: readiness.get, hold: .seconds(10),
                                          names: NameCache()) { _ in ["93.184.215.14"] }
    #expect(rcode(answer) == 0)
    #expect(answers(answer) == 1)
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func nothingButFailureIfTorIsntReadyInTime() async {
    let start = ContinuousClock.now
    let answer = await DNSAnswerer.answer(query(DNSType.a), torReady: { false }, hold: .milliseconds(300),
                                          names: NameCache()) { _ in
        Issue.record("must not resolve")
        return []
    }
    #expect(rcode(answer) == 2)
    #expect(ContinuousClock.now - start >= .milliseconds(300))
}

@Test func otherTypesDontWaitForTor() async {
    // Tor never answers them, so their empty answer needn't wait.
    let start = ContinuousClock.now
    let answer = await DNSAnswerer.answer(query(65), torReady: { false }, hold: .seconds(10),
                                          names: NameCache()) { _ in
        Issue.record("must not resolve")
        return []
    }
    #expect(rcode(answer) == 0)
    #expect(answers(answer) == 0)
    #expect(ContinuousClock.now - start < .seconds(1))
}

@Test func otherTypesGetAnEmptyAnswer() async {
    let answer = await DNSAnswerer.answer(query(16), torReady: { true }, names: NameCache()) { _ in
        Issue.record("must not resolve")
        return []
    }
    #expect(rcode(answer) == 0)
    #expect(answers(answer) == 0)
}

@Test func aFailedLookupIsAServerFailure() async {
    let answer = await DNSAnswerer.answer(query(DNSType.aaaa), torReady: { true }, names: NameCache()) { _ in
        throw EngineError("no exit")
    }
    #expect(rcode(answer) == 2)
}

@Test func garbageGetsNoAnswer() async {
    #expect(await DNSAnswerer.answer(Data([1, 2, 3]), torReady: { true }, names: NameCache()) { _ in [] } == nil)
}
