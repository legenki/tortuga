import Network

/// Addresses that stay on this Mac or its network (loopback, private,
/// link-local, multicast): never sent through Tor.
public enum LocalAddress {
    public static func isLocal(_ ip: String) -> Bool {
        if let v4 = IPv4Address(ip) { return isLocal(v4: [UInt8](v4.rawValue)) }
        if let v6 = IPv6Address(ip) {
            let b = [UInt8](v6.rawValue)
            if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }      // ::1
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                   // fe80::/10
            if (b[0] & 0xFE) == 0xFC { return true }                                   // fc00::/7
            if b[0] == 0xFF { return true }                                            // ff00::/8
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {   // ::ffff:a.b.c.d
                return isLocal(v4: Array(b[12..<16]))
            }
            return false
        }
        return false
    }

    private static func isLocal(v4 b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): true
        case (172, 16...31): true
        case (224...255, _): true   // multicast, reserved, broadcast
        default: false
        }
    }
}
