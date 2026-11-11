import Foundation
import Network

public struct DNSQuestion: Sendable, Equatable {
    public var name: String
    public var type: UInt16
    public var klass: UInt16
}

public struct DNSQuery: Sendable, Equatable {
    public var id: UInt16
    public var flags: UInt16
    public var question: DNSQuestion
}

public enum DNSType {
    public static let a: UInt16 = 1
    public static let aaaa: UInt16 = 28

    /// Types Tor can answer (it resolves names to addresses, nothing else).
    public static func resolvable(_ type: UInt16) -> Bool { type == a || type == aaaa }
}

/// The DNS proxy's messages: read a query's first question, write answers.
/// Names are read with compression and written without it.
public enum DNSMessage {
    public enum ParseError: Error { case short, badLabel, loop }

    public static func parseQuery(_ data: Data) -> DNSQuery? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        let qdcount = Int(b[4]) << 8 | Int(b[5])
        guard qdcount >= 1 else { return nil }
        var offset = 12
        guard let name = try? readName(b, at: &offset), offset + 4 <= b.count else { return nil }
        let type = UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
        let klass = UInt16(b[offset + 2]) << 8 | UInt16(b[offset + 3])
        return DNSQuery(id: UInt16(b[0]) << 8 | UInt16(b[1]),
                        flags: UInt16(b[2]) << 8 | UInt16(b[3]),
                        question: DNSQuestion(name: name, type: type, klass: klass))
    }

    /// The name at `offset`, following compression pointers; `offset` moves
    /// past the name as it is written at that place.
    static func readName(_ b: [UInt8], at offset: inout Int) throws -> String {
        var labels: [String] = []
        var at = offset
        var jumped = false
        var jumps = 0
        while true {
            guard at < b.count else { throw ParseError.short }
            let length = Int(b[at])
            if length & 0xC0 == 0xC0 {
                guard at + 1 < b.count else { throw ParseError.short }
                jumps += 1
                guard jumps <= 16 else { throw ParseError.loop }
                if !jumped { offset = at + 2 }
                jumped = true
                at = (length & 0x3F) << 8 | Int(b[at + 1])
                continue
            }
            guard length & 0xC0 == 0 else { throw ParseError.badLabel }
            if length == 0 {
                if !jumped { offset = at + 1 }
                return labels.joined(separator: ".")
            }
            guard at + 1 + length <= b.count else { throw ParseError.short }
            labels.append(String(decoding: b[(at + 1)...(at + length)], as: UTF8.self))
            at += 1 + length
        }
    }

    /// NOERROR with the addresses that match the question's type.
    public static func answer(_ q: DNSQuery, addresses: [String], ttl: UInt32 = 60) -> Data {
        let records: [[UInt8]] = addresses.compactMap { address in
            if q.question.type == DNSType.a, let v4 = IPv4Address(address) { return [UInt8](v4.rawValue) }
            if q.question.type == DNSType.aaaa, let v6 = IPv6Address(address), IPv4Address(address) == nil {
                return [UInt8](v6.rawValue)
            }
            return nil
        }
        var out = header(q, rcode: 0, answers: records.count) + question(q)
        for rdata in records {
            out += encodeName(q.question.name)
            out += be16(q.question.type) + be16(1) + be32(ttl) + be16(UInt16(rdata.count)) + rdata
        }
        return Data(out)
    }

    /// NOERROR, no answers: for types Tor can't resolve.
    public static func empty(_ q: DNSQuery) -> Data { Data(header(q, rcode: 0, answers: 0) + question(q)) }

    /// SERVFAIL: Tor isn't ready, or the lookup failed.
    public static func serverFailure(_ q: DNSQuery) -> Data { Data(header(q, rcode: 2, answers: 0) + question(q)) }

    private static func header(_ q: DNSQuery, rcode: UInt8, answers: Int) -> [UInt8] {
        let opcode = UInt8((q.flags >> 8) & 0x78)
        let recursionDesired = UInt8((q.flags >> 8) & 0x01)
        let flags1 = 0x80 | opcode | recursionDesired
        let flags2 = 0x80 | (rcode & 0x0F)
        return be16(q.id) + [flags1, flags2] + be16(1) + be16(UInt16(answers)) + be16(0) + be16(0)
    }

    private static func question(_ q: DNSQuery) -> [UInt8] {
        encodeName(q.question.name) + be16(q.question.type) + be16(q.question.klass)
    }

    private static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out += [UInt8(bytes.count)] + bytes
        }
        return out + [0]
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
