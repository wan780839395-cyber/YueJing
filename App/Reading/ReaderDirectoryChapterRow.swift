import SwiftUI

/// Label only. Stable chapter identity, ownership checks and selection stay in the caller.
@MainActor
struct ReaderDirectoryChapterRow: View {
    let title: String
    let ordinal: Int
    var totalCount: Int = 0
    let isCurrent: Bool
    let appearance: ReaderToolAppearance
    @Environment(\.dynamicTypeSize) private var dynamicType

    static let horizontalColumnLimit = 6
    static let columnSpacing: CGFloat = 14

    static func ordinalColumnDigits(ordinal: Int, totalCount: Int) -> Int {
        let highestOrdinal = max(1, max(ordinal, totalCount))
        return max(2, String(highestOrdinal).count)
    }

    private var columnDigits: Int {
        Self.ordinalColumnDigits(ordinal: ordinal, totalCount: totalCount)
    }

    private var usesStackedLayout: Bool {
        dynamicType.isAccessibilitySize || columnDigits > Self.horizontalColumnLimit
    }

    private var ordinalFont: Font {
        if usesStackedLayout {
            return .system(.footnote, design: .serif).weight(.semibold)
        }
        return columnDigits >= 5
            ? .system(.footnote, design: .serif).weight(.semibold)
            : .system(.subheadline, design: .serif).weight(.semibold)
    }

    private var ordinalPlaceholder: String {
        String(repeating: "8", count: columnDigits)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Subtle vertical bookmark indicator for the active chapter
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isCurrent ? appearance.accent : Color.clear)
                .frame(width: 3, height: 22)
                .accessibilityHidden(true)

            Group {
                if usesStackedLayout {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ordinalLabel
                            Spacer(minLength: 8)
                            currentCheckmark
                        }
                        titleText
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
                        measuredOrdinalColumn
                        titleText
                        currentCheckmark
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appearance.selection)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }

    private var measuredOrdinalColumn: some View {
        Text(ordinalPlaceholder)
            .font(ordinalFont)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .overlay(alignment: .leading) {
                ordinalLabel
            }
            .accessibilityHidden(true)
    }

    private var ordinalLabel: some View {
        Text("\(ordinal)")
            .font(ordinalFont)
            .monospacedDigit()
            .foregroundStyle(isCurrent ? appearance.accent : appearance.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(.body, design: .serif).weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? appearance.foreground : appearance.foreground.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var currentCheckmark: some View {
        if isCurrent {
            Image(systemName: "bookmark.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.accent)
                .accessibilityHidden(true)
        }
    }
}
