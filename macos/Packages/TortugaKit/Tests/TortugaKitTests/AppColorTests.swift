import CoreGraphics
import Testing
@testable import TortugaKit

@Test func anAppKeepsItsColour() {
    // Fixed values: a stable hash, not Swift's per-run seeded one.
    #expect(AppColor.index(for: "com.apple.Safari") == AppColor.index(for: "com.apple.Safari"))
    #expect((0..<AppColor.count).contains(AppColor.index(for: "")))
}

@Test func theHashIsPinned() {
    // A literal, so a change to the hash (and every app's colour) is noticed.
    #expect(AppColor.index(for: "com.apple.Safari") == 2)
}

@Test func theNormalDemoAppsGetDifferentColours() {
    let ids = ["com.apple.Safari", "ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap", "com.apple.Music"]
    #expect(Set(ids.map(AppColor.index(for:))).count == 4)
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

@Test func slotsSpreadDotsWithoutOverlap() {
    // Exit dots are 8 points across; spread ones may touch but not cover each other.
    #expect(AppColor.offset(slot: 0) == .zero)
    let offsets = (0..<12).map { AppColor.offset(slot: $0) }
    for i in offsets.indices {
        for j in offsets.indices where j > i {
            let d = hypot(offsets[i].dx - offsets[j].dx, offsets[i].dy - offsets[j].dy)
            #expect(d >= 7.5, "slots \(i) and \(j): \(d)")
        }
    }
}
