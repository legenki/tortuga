import AppKit
import SwiftUI
import TortugaKit

extension Color {
    /// The route green: the extension's --accent.
    static let route = Color(light: 0x16A34A, dark: 0x34D399)
    /// Bridges: the extension's --focus.
    static let bridge = Color(light: 0x2563EB, dark: 0x60A5FA)
    /// Connecting: the extension's --caution.
    static let caution = Color(light: 0xD97706, dark: 0xFBBF24)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

extension Status {
    func text(bridge: BridgeKind?) -> String {
        switch self {
        case .off: "Direct — not using Tor"
        case .starting(let step, let progress): "Connecting… \(Int(progress * 100))% · \(step)"
        case .on: bridge.map { "Tor on via \($0.title)" } ?? "Tor on"
        case .blocked(let reason): "\(reason) — traffic is blocked"
        case .failed(let reason): reason
        }
    }

    var color: Color {
        switch self {
        case .off: .secondary
        case .starting: .caution
        case .on: .route
        case .blocked, .failed: .red
        }
    }
}
