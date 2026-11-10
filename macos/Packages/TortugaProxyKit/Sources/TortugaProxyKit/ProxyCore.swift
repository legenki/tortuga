public actor ProxyCore {
    /// Signing identifiers of our own programs: their traffic goes out directly.
    public static let ownIDs: Set<String> = ["tortuga-helper", "lyrebird"]
}
