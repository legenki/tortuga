import CoreGraphics
import Testing
@testable import TortugaKit

@Test func anAppKeepsItsColour() {
    // Fixed values: a stable hash, not Swift's per-run seeded one.
    #expect(AppColor.index(for: "com.apple.Safari") == AppColor.index(for: "com.apple.Safari"))
    #expect(AppColor.index(for: "com.apple.Safari") == Int(AppColor.fnv1a("com.apple.Safari") % UInt32(AppColor.count)))
    #expect((0..<AppColor.count).contains(AppColor.index(for: "")))
}

@Test func coloursAreSpreadAcrossApps() {
    let ids = ["com.apple.Safari", "ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap", "com.apple.Music",
               "org.mozilla.firefox", "com.google.Chrome", "us.zoom.xos", "com.spotify.client"]
    #expect(Set(ids.map(AppColor.index(for:))).count >= 4)
}

@Test func fnv1aMatchesTheReference() {
    #expect(AppColor.fnv1a("") == 0x811C9DC5)
    #expect(AppColor.fnv1a("a") == 0xE40C292C)
    #expect(AppColor.fnv1a("foobar") == 0xBF9CF968)
}

@Test func slotsSpreadDots() {
    #expect(AppColor.offset(slot: 0) == .zero)
    let offsets = (0..<8).map { AppColor.offset(slot: $0) }
    #expect(Set(offsets.map { "\($0.dx.rounded()),\($0.dy.rounded())" }).count == 8)
    for o in offsets.dropFirst() { #expect(abs(hypot(o.dx, o.dy) - 6) < 0.001) }
}
