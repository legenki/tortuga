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
    var color: Color {
        switch self {
        case .off: .secondary
        case .starting: .caution
        case .on: .route
        case .blocked, .failed: .red
        }
    }
}

extension View {
    /// A glass card behind the content. The glass sits in the background
    /// rather than on the view itself: glassEffect on a view takes the clicks
    /// meant for the buttons inside it.
    func glassCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        background {
            Color.clear.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension Color {
    /// App route colours, by AppColor.index. Not green (the trunk) and not
    /// blue (bridges), so an app's line never looks like either.
    static let appPalette: [Color] = [
        Color(light: 0x0284C7, dark: 0x38BDF8), // sky
        Color(light: 0x7C3AED, dark: 0xA78BFA), // violet
        Color(light: 0xDB2777, dark: 0xF472B6), // pink
        Color(light: 0xEA580C, dark: 0xFB923C), // orange
        Color(light: 0x0D9488, dark: 0x2DD4BF), // teal
        Color(light: 0x4F46E5, dark: 0x818CF8), // indigo
        Color(light: 0xCA8A04, dark: 0xFACC15), // yellow
        Color(light: 0x65A30D, dark: 0xA3E635), // lime
    ]

    static func app(_ id: String) -> Color { appPalette[AppColor.index(for: id)] }
}
