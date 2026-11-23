import CoreGraphics

/// Which of the palette's colours an app's route is drawn in, and how dots
/// that share a place are spread apart. The palette itself is in TortugaUI.
public enum AppColor {
    public static let count = 8

    /// The same for an app on every run: FNV-1a of its identifier, not
    /// Swift's `hashValue`, which is seeded per process.
    public static func index(for appID: String) -> Int {
        Int(fnv1a(appID) % UInt32(count))
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
    /// the others sit 6 points away at golden-angle steps.
    public static func offset(slot: Int) -> CGVector {
        guard slot > 0 else { return .zero }
        let angle = Double(slot) * 137.50776 * .pi / 180
        return CGVector(dx: 6 * cos(angle), dy: 6 * sin(angle))
    }
}
