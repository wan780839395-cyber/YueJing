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

    static let horizontalInset: CGFloat = 22
    static let minimumControlHeight: CGFloat = AppVisualStyle.minimumControlHeight
    static let coverWidth: CGFloat = 44
    static let coverHeight: CGFloat = 59
    static let entryCornerRadius: CGFloat = 15

    static var titleFont: Font { AppVisualStyle.pageTitleFont }
    static var bookTitleFont: Font { AppVisualStyle.bookTitleFont }

    var controlColorScheme: ColorScheme { style.controlColorScheme }
    var page: Color { style.page }
    var surface: Color { style.surface }
    var foreground: Color { style.foreground }
    var secondary: Color { style.secondary }
    var edge: Color { style.edge }
    var accent: Color { style.accent }
    var coverSurface: Color { style.coverSurface }
}
