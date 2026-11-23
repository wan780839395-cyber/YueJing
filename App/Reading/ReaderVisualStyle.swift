import ReaderDomain
import SwiftUI
import UIKit

/// Shared native reader chrome vocabulary; canvas typography and colors are separate.
/// Reading canvas colors, navigation and persisted preferences remain separate.
@MainActor
enum ReaderVisualStyle {
    static let panelHorizontalInset: CGFloat = 20
    static let panelTopInset: CGFloat = 12
    static let panelHeaderSpacing: CGFloat = 10
    static let panelCornerRadius: CGFloat = 26
    static let controlCornerRadius: CGFloat = 16
    static let panelDividerHeight: CGFloat = AppVisualStyle.dividerHeight
    static let minimumControlHeight: CGFloat = AppVisualStyle.minimumControlHeight
    static let panelActionMinimumWidth: CGFloat = 56
    static let headingMarkWidth: CGFloat = 3.5
    static let headingMarkHeight: CGFloat = 20
    static let toolPanelMaximumWidth: CGFloat = 640

    // Semantic styles retain Dynamic Type; no bundled or downloaded fonts.
    static var panelTitleFont: Font { AppVisualStyle.panelTitleFont }
    static var panelActionFont: Font { AppVisualStyle.actionFont }

    static func surface(for theme: ReaderTheme) -> Color {
        switch theme {
        case .paper: rgb(249, 246, 238)
        case .light: rgb(251, 252, 250)
        case .dark: rgb(30, 35, 32)
        }
    }

    static func elevatedSurface(for theme: ReaderTheme) -> Color {
        switch theme {
        case .paper: rgb(253, 251, 246)
        case .light: rgb(255, 255, 255)
        case .dark: rgb(38, 45, 41)
        }
    }

    static func edge(for theme: ReaderTheme) -> Color {
        let dark = theme == .dark
        return Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                return dark
                    ? UIColor(red: 0.67, green: 0.80, blue: 0.72, alpha: 1)
                    : UIColor(red: 0.20, green: 0.39, blue: 0.31, alpha: 1)
            }
            switch theme {
            case .paper:
                return UIColor(red: 215.0 / 255, green: 208.0 / 255, blue: 193.0 / 255, alpha: 1)
            case .light:
                return UIColor(red: 218.0 / 255, green: 224.0 / 255, blue: 217.0 / 255, alpha: 1)
            case .dark:
                return UIColor(red: 58.0 / 255, green: 70.0 / 255, blue: 62.0 / 255, alpha: 1)
            }
        })
    }

    static func accent(for theme: ReaderTheme) -> Color {
        switch theme {
        case .paper: rgb(43, 106, 86)
        case .light: rgb(36, 98, 82)
        case .dark: rgb(142, 202, 177)
        }
    }

    static func sealAccent(for theme: ReaderTheme) -> Color {
        theme == .dark ? rgb(222, 124, 108) : rgb(181, 72, 58)
    }

    static func sectionSurface(for theme: ReaderTheme) -> Color {
        switch theme {
        case .paper: rgb(240, 235, 223)
        case .light: rgb(241, 244, 240)
        case .dark: rgb(39, 46, 42)
        }
    }

    static func selectionSurface(for theme: ReaderTheme) -> Color {
        switch theme {
        case .paper: rgb(224, 232, 223)
        case .light: rgb(225, 236, 230)
        case .dark: rgb(48, 66, 56)
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
