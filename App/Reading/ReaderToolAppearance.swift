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

/// Depends on geometry/font size only, never on tools visibility or panel selection.
struct ReaderToolMetrics {
    let compactHeight: Bool
    let verticalButtons: Bool
    let titleHeight: CGFloat
    let dockHeight: CGFloat
    let panelHeight: CGFloat
    let controlHeight: CGFloat
    init(height: CGFloat, scaledControl: CGFloat, titleLine: CGFloat, accessibilityFont: Bool) {
        compactHeight = height < 440
        verticalButtons = accessibilityFont && !compactHeight
        controlHeight = compactHeight ? 44 : max(44, scaledControl)
        titleHeight = compactHeight ? max(52, min(titleLine + 8, height * 0.26)) : max(60, titleLine * 2 + 16)
        dockHeight = controlHeight * (verticalButtons ? 2 : 1) + (verticalButtons ? 8 : 0) + 16
        let available = max(dockHeight, height - titleHeight - 36)
        panelHeight = min(available, max(dockHeight + 160, height * 0.72))
    }
    var topClearance: CGFloat { titleHeight + 12 }
    var bottomClearance: CGFloat { dockHeight + 12 }
}
