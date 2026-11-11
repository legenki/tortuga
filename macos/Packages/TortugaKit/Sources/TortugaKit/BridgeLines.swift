import Foundation
import Network

/// Bridge lines pasted by the user, as bridges.torproject.org hands them out:
/// `obfs4 1.2.3.4:443 <40 hex> cert=… iat-mode=0`, with or without a leading
/// `Bridge`. The rules match the extension's (extension/src/lib/bridges.ts).
public enum BridgeLines {
    public struct Parsed: Sendable, Equatable {
        /// Good lines, each starting with "Bridge ".
        public var lines: [String]
        public var errors: [String]
    }

    /// `ip:port` as bridge lines have it: IPv4 or bracketed IPv6 (no host
    /// names: Arti takes neither) and a port from 1 to 65535.
    public static func isAddress(_ text: String) -> Bool {
        guard let match = text.wholeMatch(of: #/(?:(\d{1,3}(?:\.\d{1,3}){3})|\[([0-9A-Fa-f:.]+)\]):(\d{1,5})/#) else {
            return false
        }
        guard let port = Int(match.output.3), (1...65535).contains(port) else { return false }
        if let v4 = match.output.1 {
            return v4.split(separator: ".").allSatisfy { (Int($0) ?? 256) <= 255 }
        }
        if let v6 = match.output.2 {
            return IPv6Address(String(v6)) != nil
        }
        return false
    }

    public static func parse(_ text: String, for kind: BridgeKind) -> Parsed {
        var out = Parsed(lines: [], errors: [])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prefix = line.range(of: #"^Bridge\s+"#, options: [.regularExpression, .caseInsensitive]) {
                line.removeSubrange(prefix)
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let place = "Line \(index + 1)"
            let transport = parts[0]
            if transport != kind.rawValue {
                out.errors.append("\(place): starts with “\(transport)”, expected “\(kind.rawValue)”")
            } else if parts.count < 2 || !isAddress(parts[1]) {
                out.errors.append("\(place): no IP address:port after “\(kind.rawValue)” (like 192.0.2.1:443 or [2001:db8::1]:443)")
            } else if parts.count < 3 || parts[2].wholeMatch(of: #/[0-9A-Fa-f]{40}/#) == nil {
                out.errors.append("\(place): no 40-character fingerprint after the address")
            } else {
                out.lines.append("Bridge \(line)")
            }
        }
        return out
    }
}
