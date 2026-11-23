import Foundation
import TortugaKit

/// Which apps make the first Tor list: the browsers on this Mac, found by
/// the app (apps that open https links), minus ones that shouldn't be there.
public enum InstalledBrowsers {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var path: String
        public var name: String

        public init(id: String, path: String, name: String) {
            self.id = id
            self.path = path
            self.name = name
        }
    }

    /// Tor Browser runs its own Tor; Tor over Tor only slows it down.
    static let excluded: Set<String> = ["org.torproject.torbrowser"]

    public static func pick(_ candidates: [Candidate], own: String?) -> [AppID] {
        var seen = Set<String>()
        return candidates
            .filter { !excluded.contains($0.id) && $0.id != own && !isBuildCopy($0.path) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { AppID($0.id, path: $0.path, name: $0.name) }
    }

    /// On a mounted disk image, or built by Xcode.
    static func isBuildCopy(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }
}
