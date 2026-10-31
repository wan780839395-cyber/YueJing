import SwiftUI

/// Owns presentation only. The caller retains the button, guard, focus and action.
@MainActor
struct ReaderPanelHeader<Action: View>: View {
    let title: LocalizedStringKey
    let appearance: ReaderToolAppearance
    private let action: Action

    init(title: LocalizedStringKey, appearance: ReaderToolAppearance,
         @ViewBuilder action: () -> Action) {
        self.title = title
        self.appearance = appearance
        self.action = action()
    }

    var body: some View {
        VStack(spacing: ReaderVisualStyle.panelHeaderSpacing) {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(ReaderVisualStyle.panelTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                action
            }
            .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
            Rectangle()
                .fill(appearance.edge.opacity(0.65))
                .frame(height: ReaderVisualStyle.panelDividerHeight)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
    }
}
