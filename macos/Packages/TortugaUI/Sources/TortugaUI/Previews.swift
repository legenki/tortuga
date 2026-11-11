import SwiftUI
import TortugaKit

/// Hosts a view on a running DemoEngine, with Tor switched on if asked.
struct PreviewHost<Content: View>: View {
    @State private var model: AppModel
    private let tor: Bool
    private let content: Content

    init(_ scenario: Scenario, tor: Bool = true, @ViewBuilder content: () -> Content) {
        _model = State(initialValue: AppModel(engine: DemoEngine.running(scenario)))
        self.tor = tor
        self.content = content()
    }

    var body: some View {
        content
            .environment(model)
            .task {
                if tor { await model.perform(.mode) { try await $0.setMode(.tor) } }
            }
    }
}

#Preview("Window, normal") {
    PreviewHost(.normal) { MainWindow() }.frame(width: 760, height: 540)
}

#Preview("Route, many apps") {
    PreviewHost(.manyApps) { RouteView() }.frame(width: 600, height: 640)
}

#Preview("Route, Tor dies") {
    PreviewHost(.torDies) { RouteView() }.frame(width: 600, height: 400)
}

#Preview("Bridges, bridge fails") {
    PreviewHost(.bridgeFails) { BridgesView() }.frame(width: 600, height: 640)
}

#Preview("Downloads") {
    PreviewHost(.normal, tor: false) { DownloadsView() }.frame(width: 600, height: 360)
}

#Preview("Menu panel") {
    PreviewHost(.normal) { MenuPanel() }
}

#Preview("First run") {
    FirstRunView {}
}
