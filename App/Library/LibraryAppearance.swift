import SwiftUI

/// Explicit management-page appearance, never reader preferences.
@MainActor
struct LibraryAppearance {
    let colorScheme: ColorScheme
    let appAppearance: AppAppearance

    // Existing consumers remain source-compatible; only explicit callers track selection.
    init(colorScheme: ColorScheme, appAppearance: AppAppearance = .defaultAppearance) {
        self.colorScheme = colorScheme
        self.appAppearance = appAppearance
    }

    private var style: AppVisualStyle { AppVisualStyle(appearance: appAppearance, colorScheme: colorScheme) }

    static let horizontalInset: CGFloat = 20
    static let minimumControlHeight: CGFloat = AppVisualStyle.minimumControlHeight
    static let coverWidth: CGFloat = 54
    static let coverHeight: CGFloat = 76
    static let heroCoverWidth: CGFloat = 82
    static let heroCoverHeight: CGFloat = 116
    static let cardCornerRadius: CGFloat = 20
    static let entryCornerRadius: CGFloat = 16
    static let contentBottomSpacing: CGFloat = 16

    static var titleFont: Font { AppVisualStyle.pageTitleFont }
    static var sectionTitleFont: Font { AppVisualStyle.sectionTitleFont }
    static var bookTitleFont: Font { AppVisualStyle.bookTitleFont }
    static var heroBookTitleFont: Font { AppVisualStyle.heroBookTitleFont }

    var controlColorScheme: ColorScheme { style.controlColorScheme }
    var isDarkSurface: Bool { style.isDarkSurface }
    var page: Color { style.page }
    var surface: Color { style.surface }
    var elevatedSurface: Color { style.elevatedSurface }
    var subtleSurface: Color { style.subtleSurface }
    var foreground: Color { style.foreground }
    var secondary: Color { style.secondary }
    var edge: Color { style.edge }
    var accent: Color { style.accent }
    var accentSoft: Color { style.accentSoft }
    var sealAccent: Color { style.sealAccent }
    var sealSoft: Color { style.sealSoft }
    var coverSurface: Color { style.coverSurface }
    var groupSurface: Color { style.surface }
    var softSelection: Color { style.accentSoft }
    var shadow: Color { style.shadow }
    var cardShadow: Color { style.cardShadow }
}
