import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct ReaderToolAppearance {
    let theme: ReaderTheme
    let reduceTransparency: Bool
    var surface: Color {
        Color(uiColor: theme == .dark ? UIColor(white: 0.13, alpha: 1)
            : UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1))
    }
    var foreground: Color { Color(uiColor: theme.foreground) }
    var edge: Color { foreground.opacity(theme == .dark ? 0.16 : 0.10) }
    var accent: Color {
        theme == .dark ? Color(red: 0.80, green: 0.60, blue: 0.52)
            : Color(red: 0.57, green: 0.34, blue: 0.28)
    }
    var fill: Color { surface.opacity(reduceTransparency ? 1 : 0.97) }
}

/// Tools geometry only. Never reserves space in the reading viewport.
struct ReaderToolMetrics {
    let compactHeight: Bool
    let verticalButtons: Bool
    let titleHeight: CGFloat
    let controlHeight: CGFloat
    init(height: CGFloat, scaledControl: CGFloat, titleLine: CGFloat, accessibilityFont: Bool) {
        compactHeight = height < 440
        verticalButtons = accessibilityFont && !compactHeight
        controlHeight = compactHeight ? 44 : max(44, scaledControl)
        titleHeight = max(52, titleLine * (accessibilityFont && !compactHeight ? 2 : 1) + 20)
    }
}
