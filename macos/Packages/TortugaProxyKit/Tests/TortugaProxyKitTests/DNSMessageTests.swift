import Foundation
import Testing
@testable import TortugaProxyKit

/// A query for example.com, type `type`, id 0x1234, recursion desired, as dig sends it.
private func query(type: UInt16 = 1) -> Data {
    var b: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]
    b += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]
    return Data(b)
}

@Test func parsesAQuery() throws {
    let q = try #require(DNSMessage.parseQuery(query()))
    #expect(q.id == 0x1234)
    #expect(q.question == DNSQuestion(name: "example.com", type: DNSType.a, klass: 1))
}

@Test func refusesGarbage() {
    #expect(DNSMessage.parseQuery(Data([0x12, 0x34])) == nil)
    var noQuestion = [UInt8](query())
    noQuestion[5] = 0
    #expect(DNSMessage.parseQuery(Data(noQuestion)) == nil)
}

@Test func readsCompressedNames() throws {
    // "com" at 0, then "example" + pointer to 0 at 5.
    let bytes: [UInt8] = [3] + Array("com".utf8) + [0] + [7] + Array("example".utf8) + [0xC0, 0x00]
    var offset = 5
    #expect(try DNSMessage.readName(bytes, at: &offset) == "example.com")
    #expect(offset == 15)
}

@Test func refusesPointerLoops() {
    let bytes: [UInt8] = [0xC0, 0x00]
    var offset = 0
    #expect(throws: DNSMessage.ParseError.self) { try DNSMessage.readName(bytes, at: &offset) }
}

@Test func answersWithTheAddressesOfTheAskedType() throws {
    let q = try #require(DNSMessage.parseQuery(query()))
    let answer = [UInt8](DNSMessage.answer(q, addresses: ["93.184.215.14", "2606:2800::1"], ttl: 60))
    #expect(Array(answer[0..<2]) == [0x12, 0x34])
    #expect(answer[2] & 0x80 == 0x80)                // a response
    #expect(answer[2] & 0x01 == 0x01)                // recursion desired, copied
    #expect(answer[3] & 0x80 == 0x80)                // recursion available
    #expect(answer[3] & 0x0F == 0)                   // NOERROR
    #expect(Array(answer[4..<12]) == [0, 1, 0, 1, 0, 0, 0, 0])  // 1 question, 1 answer (the A only)
    #expect(Array(answer.suffix(4)) == [93, 184, 215, 14])
    #expect(Array(answer.suffix(14).prefix(10)) == [0, 1, 0, 1, 0, 0, 0, 60, 0, 4])  // A, IN, TTL 60, 4 bytes
}

@Test func aaaaAnswersCarrySixteenBytes() throws {
    let q = try #require(DNSMessage.parseQuery(query(type: DNSType.aaaa)))
    let answer = [UInt8](DNSMessage.answer(q, addresses: ["93.184.215.14", "2606:2800::1"], ttl: 60))
    #expect(Array(answer[6..<8]) == [0, 1])
    #expect(Array(answer.suffix(16)) == [0x26, 0x06, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
}

@Test func emptyAndFailureAnswers() throws {
    let q = try #require(DNSMessage.parseQuery(query(type: 16)))
    let empty = [UInt8](DNSMessage.empty(q))
    #expect(empty[3] & 0x0F == 0)
    #expect(Array(empty[6..<8]) == [0, 0])
    let failed = [UInt8](DNSMessage.serverFailure(q))
    #expect(failed[3] & 0x0F == 2)
    #expect(Array(failed[6..<8]) == [0, 0])
}

@Test func onlyAddressTypesGoThroughTor() {
    #expect(DNSType.resolvable(DNSType.a))
    #expect(DNSType.resolvable(DNSType.aaaa))
    #expect(!DNSType.resolvable(16))   // TXT
    #expect(!DNSType.resolvable(65))   // HTTPS
}
