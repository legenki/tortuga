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

/// The window: a glass sidebar of screens, Direct / Tor in the toolbar, and
/// the first-run card until it's dismissed.
public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didShowWelcome") private var didShowWelcome = false

    public init() {}

    public var body: some View {
        let selection = Binding<SidebarSection?>(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityIdentifier("sidebar.\(section.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.section {
            case .route: RouteView()
            case .bridges: BridgesView()
            case .exceptions: ExceptionsView()
            case .downloads: DownloadsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ModeSwitch() }
        }
        .frame(minWidth: 700, minHeight: 640)
        .sheet(isPresented: Binding(get: { !didShowWelcome }, set: { if !$0 { didShowWelcome = true } })) {
            FirstRunView { didShowWelcome = true }
        }
    }
}
