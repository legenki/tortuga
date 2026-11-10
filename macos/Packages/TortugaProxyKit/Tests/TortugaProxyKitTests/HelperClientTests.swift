import Foundation
import Testing
@testable import TortugaProxyKit

/// A helper played by the test: what the client writes, and what to answer.
final class FakeTransport: HelperTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private var written: [Data] = []
    private let lock = NSLock()

    init() {
        (incoming, feed) = AsyncStream.makeStream(of: Data.self)
    }

    func write(_ data: Data) async throws {
        lock.withLock { written.append(data) }
    }

    /// Requests written so far, decoded.
    var requests: [[String: Any]] {
        lock.withLock {
            var reader = FrameReader()
            return written.flatMap { reader.push($0) }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func send(_ json: String) { feed.yield(Framing.encode(Data(json.utf8))) }
    func close() { feed.finish() }
}

@Test func framesAreLengthPrefixedLittleEndian() {
    #expect([UInt8](Framing.encode(Data("{}".utf8))) == [2, 0, 0, 0, 0x7B, 0x7D])
}

@Test func theReaderCopesWithSplitAndJoinedFrames() {
    var reader = FrameReader()
    let two = Framing.encode(Data("{\"a\":1}".utf8)) + Framing.encode(Data("{}".utf8))
    #expect(reader.push(two.prefix(3)).isEmpty)
    #expect(reader.push(two.dropFirst(3)).map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{}"])
}

@Test func parsesTheHelpersMessages() throws {
    func parse(_ s: String) -> HelperMessage? { HelperMessage.parse(Data(s.utf8)) }
    #expect(parse(#"{"id":1,"type":"hello","payload":{"protocol":1,"version":"0.3.0","features":["apps"]}}"#)
            == HelperMessage(id: 1, event: .hello(version: "0.3.0", features: ["apps"])))
    #expect(parse(#"{"type":"tor.status","payload":{"phase":"directory","percent":40,"blocked":null}}"#)?.event
            == .torStatus(phase: "directory", percent: 40, blocked: nil))
    #expect(parse(#"{"id":2,"type":"tor.ready","payload":{"socksPort":49152}}"#)?.event == .torReady(socksPort: 49152))
    #expect(parse(#"{"type":"circuit","payload":{"site":"com.apple.Safari","bridge":"snowflake","hops":[{"role":"bridge","id":"abc","addr":null,"country":null},{"role":"middle","id":"def","addr":"1.2.3.4:9001","country":"DE"}]}}"#)?.event
            == .circuit(site: "com.apple.Safari", bridge: "snowflake", hops: [
                HelperHop(role: "bridge", id: "abc", addr: nil, country: nil),
                HelperHop(role: "middle", id: "def", addr: "1.2.3.4:9001", country: "DE"),
            ]))
    #expect(parse(#"{"id":3,"type":"resolved","payload":{"addresses":["1.2.3.4"]}}"#)?.event == .resolved(["1.2.3.4"]))
    #expect(parse(#"{"id":4,"type":"error","payload":{"code":"not_running","message":"Tor is off"}}"#)?.event
            == .error(code: "not_running", message: "Tor is off"))
    #expect(parse(#"{"id":5,"type":"bridges.lines","payload":{"lines":["Bridge obfs4 x"],"source":"builtin","country":null,"viaTor":false}}"#)?.event
            == .bridgeLines(["Bridge obfs4 x"]))
    #expect(parse(#"{"type":"something.new"}"#)?.event == .other("something.new"))
    #expect(parse("not json") == nil)
}

@Test func requestsAreWrittenWithIDs() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    let answer = Task { try await client.request(.resolve("example.com")) }
    try await waitFor { fake.requests.count == 1 }
    let sent = fake.requests[0]
    #expect(sent["type"] as? String == "tor.resolve")
    #expect((sent["payload"] as? [String: Any])?["name"] as? String == "example.com")
    let id = try #require(sent["id"] as? Int)
    fake.send(#"{"id":\#(id),"type":"resolved","payload":{"addresses":["1.2.3.4"]}}"#)
    #expect(try await answer.value == .resolved(["1.2.3.4"]))
}

@Test func errorsBecomeThrows() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    let answer = Task { try await client.request(.newCircuit(site: "com.apple.Safari")) }
    try await waitFor { fake.requests.count == 1 }
    let id = try #require(fake.requests[0]["id"] as? Int)
    fake.send(#"{"id":\#(id),"type":"error","payload":{"code":"not_running","message":"Tor is off"}}"#)
    await #expect(throws: HelperError.remote(code: "not_running", message: "Tor is off")) { try await answer.value }
}

@Test func eventsWithoutIDsGoToTheEventStream() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    var events = client.events.makeAsyncIterator()
    fake.send(#"{"type":"tor.status","payload":{"phase":"ready","percent":100,"blocked":null}}"#)
    #expect(await events.next() == .torStatus(phase: "ready", percent: 100, blocked: nil))
}

@Test func aGoneHelperFailsWaitingRequests() async throws {
    let fake = FakeTransport()
    let client = HelperClient(transport: fake)
    let answer = Task { try await client.request(.stop) }
    try await waitFor { fake.requests.count == 1 }
    fake.close()
    await #expect(throws: HelperError.gone) { try await answer.value }
}

@Test func requestBodies() throws {
    func json(_ r: HelperRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: r.encoded(id: 9)) as? [String: Any])
    }
    #expect(try json(.hello)["payload"] as? [String: Int] == ["protocol": 1])
    let start = try json(.start(bridge: "obfs4", lines: ["Bridge obfs4 x"]))
    #expect(start["type"] as? String == "tor.start")
    let bridge = try #require((start["payload"] as? [String: Any])?["bridge"] as? [String: Any])
    #expect(bridge["kind"] as? String == "obfs4")
    #expect(bridge["lines"] as? [String] == ["Bridge obfs4 x"])
    #expect(try json(.fetchBridges(kind: "webtunnel"))["type"] as? String == "bridges.fetch")
}

func waitFor(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}
