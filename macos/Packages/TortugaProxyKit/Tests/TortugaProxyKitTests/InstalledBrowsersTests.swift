import Testing
import TortugaKit
@testable import TortugaProxyKit

private func app(_ id: String, _ path: String, _ name: String) -> InstalledBrowsers.Candidate {
    InstalledBrowsers.Candidate(id: id, path: path, name: name)
}

@Test func browsersAreKeptSortedByName() {
    let picked = InstalledBrowsers.pick([
        app("org.mozilla.firefox", "/Applications/Firefox.app", "Firefox"),
        app("com.apple.Safari", "/Applications/Safari.app", "Safari"),
        app("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome"),
    ], own: "org.tortuga.app")
    #expect(picked.map(\.id) == ["org.mozilla.firefox", "com.google.Chrome", "com.apple.Safari"])
    #expect(picked.first?.path == "/Applications/Firefox.app")
    #expect(picked.first?.name == "Firefox")
}

@Test func torBrowserTortugaAndBuildCopiesAreLeftOut() {
    let picked = InstalledBrowsers.pick([
        app("org.torproject.torbrowser", "/Applications/Tor Browser.app", "Tor Browser"),
        app("org.tortuga.app", "/Applications/Tortuga.app", "Tortuga"),
        app("com.brave.Browser", "/Volumes/Brave/Brave Browser.app", "Brave Browser"),
        app("com.example.dev", "/Users/a/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/Dev.app", "Dev"),
        app("com.example.local", "/Users/a/src/build/Build/Products/Release/Local.app", "Local"),
        app("com.apple.Safari", "/Applications/Safari.app", "Safari"),
    ], own: "org.tortuga.app")
    #expect(picked.map(\.id) == ["com.apple.Safari"])
}

@Test func theSameBrowserTwiceIsListedOnce() {
    let picked = InstalledBrowsers.pick([
        app("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome"),
        app("com.google.Chrome", "/Users/a/Applications/Google Chrome.app", "Google Chrome"),
    ], own: nil)
    #expect(picked.map(\.path) == ["/Applications/Google Chrome.app"])
}

@Test func aBuildCopyListedFirstDoesNotShadowTheRealInstall() {
    let picked = InstalledBrowsers.pick([
        app("com.google.Chrome", "/Volumes/Chrome/Google Chrome.app", "Google Chrome"),
        app("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome"),
    ], own: nil)
    #expect(picked.count == 1)
    #expect(picked.first?.path == "/Applications/Google Chrome.app")
}
