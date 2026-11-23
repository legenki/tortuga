import CoreGraphics

/// Which of the palette's colours an app's route is drawn in, and how dots
/// that share a place are spread apart. The palette itself is in TortugaUI.
public enum AppColor {
    public static let count = 8

    /// The same for an app on every run: FNV-1a of its identifier, not
    /// Swift's `hashValue`, which is seeded per process, mixed with murmur3's
    /// finaliser so the low bits used by `% count` depend on every bit of
    /// every byte (plain FNV-1a's low 3 bits only see each byte's low 3).
    public static func index(for appID: String) -> Int {
        Int(fmix32(fnv1a(appID)) % UInt32(count))
    }

    static func fmix32(_ x: UInt32) -> UInt32 {
        var h = x
        h ^= h >> 16
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        h = h &* 0xC2B2_AE35
        h ^= h >> 16
        return h
    }

    static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// Where the n-th dot on a shared place goes, in points: the first stays,
    /// the others follow a sunflower spiral (golden-angle steps, radius
    /// growing with √n), so any number of 8-point dots sit at least 8 points
    /// apart. The radius is 5·√(n + 2): with 5·√n the first two would be
    /// within 7.5 points of the one in the middle.
    public static func offset(slot: Int) -> CGVector {
        guard slot > 0 else { return .zero }
        let angle = Double(slot) * 137.50776 * .pi / 180
        let radius = 5 * Double(slot + 2).squareRoot()
        return CGVector(dx: radius * cos(angle), dy: radius * sin(angle))
    }
}
