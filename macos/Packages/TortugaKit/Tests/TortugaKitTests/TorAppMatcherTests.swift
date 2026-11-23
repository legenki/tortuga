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
