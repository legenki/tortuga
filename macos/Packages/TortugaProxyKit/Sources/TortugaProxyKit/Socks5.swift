import Network

/// The client side of SOCKS5 (RFC 1928) with username/password auth
/// (RFC 1929), as the helper's server speaks it: the username is the
/// isolation key (the app), CONNECT only.
public enum Socks5 {
    public enum ReplyError: Error, Equatable {
        case badVersion, noAcceptableMethod, authFailed
        /// The server's CONNECT reply code (4: host unreachable, 5: refused…).
        case refused(UInt8)
    }

    public static let greeting: [UInt8] = [0x05, 0x01, 0x02]

    public static func auth(user: String, password: String) -> [UInt8] {
        let u = Array(user.utf8.prefix(255))
        let p = Array(password.utf8.prefix(255))
        return [0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p
    }

    public static func connect(host: String, port: Int) -> [UInt8] {
        let portBytes: [UInt8] = [UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)]
        if let v4 = IPv4Address(host) { return [0x05, 0x01, 0x00, 0x01] + [UInt8](v4.rawValue) + portBytes }
        if let v6 = IPv6Address(host) { return [0x05, 0x01, 0x00, 0x04] + [UInt8](v6.rawValue) + portBytes }
        let name = Array(host.utf8.prefix(255))
        return [0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + portBytes
    }

    /// The server's answer to `greeting`: two bytes.
    public static func checkMethod(_ reply: [UInt8]) throws {
        guard reply.count == 2, reply[0] == 0x05 else { throw ReplyError.badVersion }
        guard reply[1] == 0x02 else { throw ReplyError.noAcceptableMethod }
    }

    /// The server's answer to `auth`: two bytes.
    public static func checkAuth(_ reply: [UInt8]) throws {
        guard reply.count == 2, reply[1] == 0x00 else { throw ReplyError.authFailed }
    }

    /// The whole CONNECT reply's length, from its first five bytes; throws
    /// if the server refused.
    public static func connectReplyLength(_ head: [UInt8]) throws -> Int {
        guard head.count >= 5, head[0] == 0x05 else { throw ReplyError.badVersion }
        guard head[1] == 0x00 else { throw ReplyError.refused(head[1]) }
        switch head[3] {
        case 0x01: return 10
        case 0x04: return 22
        case 0x03: return 7 + Int(head[4])
        default: throw ReplyError.badVersion
        }
    }
}
