import SwiftUI

public enum WindowSection: String, CaseIterable, Identifiable, Sendable {
    case route, bridges

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .route: "Route"
        case .bridges: "Bridges"
        }
    }
}

/// Route | Bridges, as the system's segmented control: in the toolbar it sits
/// on the toolbar's own glass. The UI tests find it as `section.picker` and
/// click a segment by its title.
struct SectionSwitch: View {
    @Binding var section: WindowSection

    var body: some View {
        Picker("Section", selection: $section) {
            ForEach(WindowSection.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
        .accessibilityIdentifier("section.picker")
    }
}
