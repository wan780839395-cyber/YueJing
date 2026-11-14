import ReaderDomain
import SwiftUI
import UIKit

/// Shared native reader chrome vocabulary; canvas typography and colors are separate.
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
    static let toolPanelMaximumWidth: CGFloat = 640

    // Semantic styles retain Dynamic Type; no bundled or downloaded fonts.
    static var panelTitleFont: Font { AppVisualStyle.panelTitleFont }
    static var panelActionFont: Font { AppVisualStyle.actionFont }

    static func surface(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(38, 46, 41) : (theme == .paper ? rgb(247, 245, 237) : rgb(249, 250, 247))
    }

    static func edge(for theme: ReaderTheme) -> Color {
        let dark = theme == .dark
        return Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                return dark
                    ? UIColor(red: 0.67, green: 0.78, blue: 0.71, alpha: 1)
                    : UIColor(red: 0.24, green: 0.41, blue: 0.33, alpha: 1)
            }
            return dark
                ? UIColor(red: 58.0 / 255, green: 71.0 / 255, blue: 61.0 / 255, alpha: 1)
                : UIColor(red: 223.0 / 255, green: 229.0 / 255, blue: 219.0 / 255, alpha: 1)
        })
    }

    static func accent(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(171, 200, 180) : rgb(61, 105, 85)
    }

    static func sectionSurface(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(45, 53, 47) : (theme == .paper ? rgb(241, 238, 227) : rgb(241, 244, 238))
    }

    static func selectionSurface(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(59, 77, 66) : (theme == .paper ? rgb(226, 230, 213) : rgb(226, 235, 228))
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
