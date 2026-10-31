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
    static let columnSpacing: CGFloat = 16

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
            return .system(.footnote, design: .serif).weight(.medium)
        }
        return columnDigits >= 5
            ? .system(.subheadline, design: .serif).weight(.medium)
            : .system(.title3, design: .serif).weight(.medium)
    }

    private var ordinalPlaceholder: String {
        String(repeating: "8", count: columnDigits)
    }

    var body: some View {
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
        .padding(.leading, 10)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
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
            .foregroundStyle(isCurrent ? appearance.foreground : appearance.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(.body, design: .serif))
            .foregroundStyle(appearance.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var currentCheckmark: some View {
        if isCurrent {
            Image(systemName: "checkmark")
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
                .accessibilityHidden(true)
        }
    }
}
