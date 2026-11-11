import Foundation
import Testing
import TortugaKit
@testable import TortugaProxyKit

func eventually(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

/// Plays the helper: answers each request of a known type once, by id.
func serve(_ fake: FakeTransport, _ answers: [String: @Sendable (Int) -> String]) -> Task<Void, Never> {
    Task {
        var answered = Set<Int>()
        while !Task.isCancelled {
            for request in fake.requests {
                guard let id = request["id"] as? Int, !answered.contains(id),
                      let type = request["type"] as? String, let make = answers[type] else { continue }
                answered.insert(id)
                fake.send(make(id))
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

let helloAnswer: @Sendable (Int) -> String = { #"{"id":\#($0),"type":"hello","payload":{"protocol":1,"version":"0.2.0","features":["apps"]}}"# }
let resolvedAnswer: @Sendable (Int) -> String = { #"{"id":\#($0),"type":"resolved","payload":{"addresses":["116.202.120.165"]}}"# }
let readyAnswer: @Sendable (Int) -> String = { #"{"id":\#($0),"type":"tor.ready","payload":{"socksPort":40000}}"# }

final class FakeLauncher: HelperLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeTransport] = []
    private var failing = false

    var transports: [FakeTransport] { lock.withLock { made } }
    func fail() { lock.withLock { failing = true } }

    func launch(helperPath: String, ptDir: String) throws -> any HelperTransport {
        try lock.withLock {
            if failing { throw EngineError("no helper at \(helperPath)") }
            let fake = FakeTransport()
            made.append(fake)
            return fake
        }
    }
}
