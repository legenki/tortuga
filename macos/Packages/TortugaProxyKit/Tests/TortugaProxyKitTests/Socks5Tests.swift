import Testing
@testable import TortugaProxyKit

@Test func greetingOffersUsernameAuthOnly() {
    #expect(Socks5.greeting == [0x05, 0x01, 0x02])
}

@Test func authCarriesTheAppAsUsername() {
    #expect(Socks5.auth(user: "com.apple.Safari", password: "x")
            == [0x01, 16] + Array("com.apple.Safari".utf8) + [1, UInt8(ascii: "x")])
}

@Test func connectByNameByIPv4AndByIPv6() {
    #expect(Socks5.connect(host: "example.com", port: 443)
            == [0x05, 0x01, 0x00, 0x03, 11] + Array("example.com".utf8) + [0x01, 0xBB])
    #expect(Socks5.connect(host: "93.184.215.14", port: 80) == [0x05, 0x01, 0x00, 0x01, 93, 184, 215, 14, 0x00, 0x50])
    #expect(Socks5.connect(host: "2606:2800::1", port: 443)
            == [0x05, 0x01, 0x00, 0x04, 0x26, 0x06, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x01, 0xBB])
}

@Test func checksTheServersAnswers() throws {
    try Socks5.checkMethod([0x05, 0x02])
    #expect(throws: Socks5.ReplyError.noAcceptableMethod) { try Socks5.checkMethod([0x05, 0xFF]) }
    try Socks5.checkAuth([0x01, 0x00])
    #expect(throws: Socks5.ReplyError.authFailed) { try Socks5.checkAuth([0x01, 0x01]) }
}

@Test func connectReplyLengthByAddressType() throws {
    #expect(try Socks5.connectReplyLength([0x05, 0x00, 0x00, 0x01, 0]) == 10)
    #expect(try Socks5.connectReplyLength([0x05, 0x00, 0x00, 0x04, 0]) == 22)
    #expect(try Socks5.connectReplyLength([0x05, 0x00, 0x00, 0x03, 9]) == 16)
    #expect(throws: Socks5.ReplyError.refused(4)) { try Socks5.connectReplyLength([0x05, 0x04, 0x00, 0x01, 0]) }
    #expect(throws: Socks5.ReplyError.badVersion) { try Socks5.connectReplyLength([0x04, 0x00, 0x00, 0x01, 0]) }
}
