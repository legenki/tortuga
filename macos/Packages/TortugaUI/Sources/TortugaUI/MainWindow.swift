import SwiftUI
import TortugaKit

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case route, bridges, exceptions, downloads

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .route: "Route"
        case .bridges: "Bridges"
        case .exceptions: "Exceptions"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .bridges: "road.lanes"
        case .exceptions: "arrow.uturn.right"
        case .downloads: "arrow.down.circle"
        }
    }
}
