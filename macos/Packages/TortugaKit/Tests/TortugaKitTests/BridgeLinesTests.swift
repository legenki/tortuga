import Testing
@testable import TortugaKit

private let fp = String(repeating: "A1", count: 20)

@Test func addressRules() {
    #expect(BridgeLines.isAddress("192.0.2.1:443"))
    #expect(BridgeLines.isAddress("[2001:db8::1]:443"))
    #expect(!BridgeLines.isAddress("256.0.0.1:443"))
    #expect(!BridgeLines.isAddress("192.0.2.1:0"))
    #expect(!BridgeLines.isAddress("192.0.2.1:65536"))
    #expect(!BridgeLines.isAddress("[zz::1]:443"))
    #expect(!BridgeLines.isAddress("example.com:443"))
    #expect(!BridgeLines.isAddress("192.0.2.1"))
}

@Test func acceptsLinesWithOrWithoutBridge() {
    let text = "obfs4 192.0.2.1:443 \(fp) cert=x iat-mode=0\nBridge obfs4 [2001:db8::1]:443 \(fp)"
    let parsed = BridgeLines.parse(text, for: .obfs4)
    #expect(parsed.errors.isEmpty)
    #expect(parsed.lines == [
        "Bridge obfs4 192.0.2.1:443 \(fp) cert=x iat-mode=0",
        "Bridge obfs4 [2001:db8::1]:443 \(fp)",
    ])
}

@Test func skipsBlankLinesAndComments() {
    let parsed = BridgeLines.parse("\n# from the website\n  \nobfs4 192.0.2.1:443 \(fp)\n", for: .obfs4)
    #expect(parsed.lines.count == 1)
    #expect(parsed.errors.isEmpty)
}

@Test func reportsTheWrongTransport() {
    let parsed = BridgeLines.parse("webtunnel 192.0.2.1:443 \(fp)", for: .obfs4)
    #expect(parsed.errors == ["Line 1: starts with “webtunnel”, expected “obfs4”"])
}

@Test func reportsABadAddress() {
    let parsed = BridgeLines.parse("obfs4 example.com:443 \(fp)", for: .obfs4)
    #expect(parsed.errors == ["Line 1: no IP address:port after “obfs4” (like 192.0.2.1:443 or [2001:db8::1]:443)"])
}

@Test func reportsAMissingFingerprint() {
    let parsed = BridgeLines.parse("# c\nobfs4 192.0.2.1:443 nope", for: .obfs4)
    #expect(parsed.errors == ["Line 2: no 40-character fingerprint after the address"])
}
