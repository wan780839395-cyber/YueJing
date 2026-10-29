import SwiftUI

/// A lightweight visual group. Draft bindings, controls and commits remain in the caller.
@MainActor
struct ReaderSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let mark: String
    let appearance: ReaderToolAppearance
    private let content: Content

    init(title: LocalizedStringKey, detail: LocalizedStringKey, mark: String,
         appearance: ReaderToolAppearance, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.mark = mark
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(mark)
                        .font(.system(.subheadline, design: .serif).weight(.medium))
                        .foregroundStyle(appearance.accent)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(appearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(detail)
                    .font(.caption).foregroundStyle(appearance.foreground.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Rectangle().fill(appearance.edge)
                .frame(height: ReaderVisualStyle.panelDividerHeight)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
    }
}
