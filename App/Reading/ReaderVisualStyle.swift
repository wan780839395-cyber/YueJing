import ReaderDomain
import SwiftUI

/// Visual-only vocabulary for the first native pass of the frozen design.
/// Reading canvas colors, navigation and persisted preferences remain separate.
@MainActor
enum ReaderVisualStyle {
    static let panelHorizontalInset: CGFloat = 20
    static let panelTopInset: CGFloat = 12
    static let panelHeaderSpacing: CGFloat = AppVisualStyle.compactSpacing
    static let panelCornerRadius: CGFloat = 24
    static let panelDividerHeight: CGFloat = AppVisualStyle.dividerHeight
    static let minimumControlHeight: CGFloat = AppVisualStyle.minimumControlHeight
    static let panelActionMinimumWidth: CGFloat = 56
    static let headingMarkWidth: CGFloat = 3
    static let headingMarkHeight: CGFloat = 18

    // Semantic styles retain Dynamic Type; no bundled or downloaded fonts.
    static var panelTitleFont: Font { AppVisualStyle.panelTitleFont }
    static var panelActionFont: Font { AppVisualStyle.actionFont }

    static func surface(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(38, 46, 41) : (theme == .paper ? rgb(247, 245, 237) : rgb(249, 250, 247))
    }

    static func edge(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(58, 71, 61) : rgb(223, 229, 219)
    }

    static func accent(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(212, 172, 144) : rgb(139, 91, 76)
    }

    static func sectionSurface(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(45, 53, 47) : (theme == .paper ? rgb(241, 238, 227) : rgb(241, 244, 238))
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
