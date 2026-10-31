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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(detail)
                    .font(.footnote).foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(.vertical, 12)
    }
}
