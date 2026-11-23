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

/// Route | Bridges, as one glass capsule in the toolbar.
struct SectionSwitch: View {
    @Binding var section: WindowSection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WindowSection.allCases) { item in
                let on = item == section
                Button { section = item } label: {
                    Text(item.title)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.primary.opacity(on ? 0.14 : 0)))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("section.\(item.rawValue)")
            }
        }
        .padding(3)
        .background { Color.clear.glassEffect(.regular, in: .capsule) }
    }
}
