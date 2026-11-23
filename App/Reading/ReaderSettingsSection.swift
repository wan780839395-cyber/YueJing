import SwiftUI

/// A lightweight visual group. Draft bindings, controls and commits remain in the caller.
@MainActor
struct ReaderSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let appearance: ReaderToolAppearance
    private let content: Content

    init(title: LocalizedStringKey, detail: LocalizedStringKey,
         appearance: ReaderToolAppearance, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(appearance.accent)
                        .frame(width: 3, height: 14)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(.vertical, 8)
    }
}
