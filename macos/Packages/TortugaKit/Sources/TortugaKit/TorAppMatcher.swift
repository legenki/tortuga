/// Which app in the Tor list a connection belongs to, by the code-signing
/// identifier macOS reports for it.
public enum TorAppMatcher {
    /// The listed identifier itself, or the longest listed one that the
    /// identifier extends with a "." (an app's helper, like
    /// com.google.Chrome.helper for com.google.Chrome); nil when none.
    public static func match(_ signingID: String, in list: Set<String>) -> String? {
        if list.contains(signingID) { return signingID }
        return list
            .filter { signingID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }

    /// The match for the first process in `lineage` (the process itself,
    /// then its parent, grandparent, …) that matches; nil when none does.
    /// A listed app's child processes (Firefox's plugin-container, curl run
    /// from a listed Terminal) count as that app.
    public static func match(lineage: [String], in list: Set<String>) -> String? {
        for signingID in lineage {
            if let listed = match(signingID, in: list) { return listed }
        }
        return nil
    }
}
