import Testing
@testable import TortugaKit

private let list: Set<String> = ["com.google.Chrome", "com.apple.Safari", "com.google", "org.mozilla.firefox"]

@Test func aListedAppMatchesItself() {
    #expect(TorAppMatcher.match("com.apple.Safari", in: list) == "com.apple.Safari")
}

@Test func aHelperMatchesItsApp() {
    #expect(TorAppMatcher.match("com.google.Chrome.helper", in: list) == "com.google.Chrome")
    #expect(TorAppMatcher.match("com.google.Chrome.helper.Renderer", in: list) == "com.google.Chrome")
}

@Test func theLongestPrefixWins() {
    #expect(TorAppMatcher.match("com.google.Chrome.helper", in: list) != "com.google")
    #expect(TorAppMatcher.match("com.google.Drive", in: list) == "com.google")
}

@Test func onlyWholeComponentsMatch() {
    #expect(TorAppMatcher.match("com.google.ChromeX", in: ["com.google.Chrome"]) == nil)
    #expect(TorAppMatcher.match("com.apple.mail", in: list) == nil)
    #expect(TorAppMatcher.match("", in: list) == nil)
}

@Test func aChildMatchesThroughItsAncestors() {
    #expect(TorAppMatcher.match(lineage: ["org.mozilla.plugincontainer", "org.mozilla.firefox", "com.apple.launchd"], in: list)
            == "org.mozilla.firefox")
    #expect(TorAppMatcher.match(lineage: ["com.apple.curl", "com.apple.zsh", "com.google.Chrome.helper"], in: list)
            == "com.google.Chrome")
}

@Test func theNearestMatchInTheLineageWins() {
    #expect(TorAppMatcher.match(lineage: ["com.apple.Safari", "org.mozilla.firefox"], in: list) == "com.apple.Safari")
    #expect(TorAppMatcher.match(lineage: ["com.apple.curl", "org.mozilla.firefox", "com.apple.Safari"], in: list)
            == "org.mozilla.firefox")
}

@Test func aLineageWithNothingListedMatchesNothing() {
    #expect(TorAppMatcher.match(lineage: ["com.apple.curl", "com.apple.zsh", "com.apple.Terminal"], in: list) == nil)
    #expect(TorAppMatcher.match(lineage: [], in: list) == nil)
}
