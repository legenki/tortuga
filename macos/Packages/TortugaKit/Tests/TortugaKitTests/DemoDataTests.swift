import Testing
@testable import TortugaKit

@Test func seededRandomRepeats() {
    var a = SeededRandom(seed: 42)
    var b = SeededRandom(seed: 42)
    #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
}

@Test func demoObfs4LinesAreValid() {
    let parsed = BridgeLines.parse(DemoData.obfs4Lines.joined(separator: "\n"), for: .obfs4)
    #expect(parsed.errors.isEmpty)
    #expect(parsed.lines.count == 7)
}

@Test func thirtyDistinctDemoApps() {
    #expect(Set(DemoData.manyApps).count == 30)
}

@Test func engineErrorReadsAsItsMessage() {
    #expect(EngineError("Tor isn't on").localizedDescription == "Tor isn't on")
}
