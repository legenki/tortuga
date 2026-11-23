import SwiftUI
import TortugaKit

/// The window: the map fills it; the Tor list floats on the left, Route |
/// Bridges and the status pill sit in the toolbar, and the first-run card
/// shows until it's dismissed.
public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didShowWelcome") private var didShowWelcome = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        let onRoute = model.section == .route
        ZStack(alignment: .topLeading) {
            RouteMap(state: model.state,
                     highlighted: onRoute ? model.hoveredApp ?? model.expandedApp : nil,
                     focused: onRoute ? model.expandedApp : nil,
                     insets: EdgeInsets(top: 64, leading: onRoute ? AppPanel.width + 36 : 24, bottom: 24, trailing: 24),
                     dimmed: !onRoute) { id in
                withAnimation(.snappy) { model.expandedApp = id }
            }
            .ignoresSafeArea()

            if onRoute {
                AppPanel()
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                VStack {
                    ProblemBanner()
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.leading, AppPanel.width + 24)
                .frame(maxWidth: .infinity)
            } else {
                BridgesView()
                    .frame(width: 480)
                    .frame(maxHeight: 560)
                    .glassCard(cornerRadius: 20)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { SectionSwitch(section: $model.section) }
            ToolbarItem(placement: .primaryAction) { StatusPill(showsGuard: true) }
        }
        .navigationTitle("")
        .frame(minWidth: 700, minHeight: 640)
        .sheet(isPresented: Binding(get: { !didShowWelcome }, set: { if !$0 { didShowWelcome = true } })) {
            FirstRunView { didShowWelcome = true }
        }
    }
}
