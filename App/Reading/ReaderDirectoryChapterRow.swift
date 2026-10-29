import SwiftUI

/// Label only. Stable chapter identity, ownership checks and selection stay in the caller.
@MainActor
struct ReaderDirectoryChapterRow: View {
    let title: String
    let ordinal: Int
    let isCurrent: Bool
    let appearance: ReaderToolAppearance
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The ordinal is decorative; do not crowd the full title at accessibility sizes.
            if !dynamicType.isAccessibilitySize {
                Text("\(ordinal)")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? appearance.accent : appearance.foreground.opacity(0.7))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 32, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(isCurrent ? appearance.accent : appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.subheadline).foregroundStyle(appearance.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(appearance.accent)
                    .frame(width: ReaderVisualStyle.headingMarkWidth, height: ReaderVisualStyle.headingMarkHeight)
                    .accessibilityHidden(true)
            }
        }
    }
}
