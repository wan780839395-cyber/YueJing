import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct ReaderToolAppearance {
    let theme: ReaderTheme
    let reduceTransparency: Bool
    var surface: Color { ReaderVisualStyle.surface(for: theme) }
    var foreground: Color { Color(uiColor: theme.foreground) }
    var edge: Color { ReaderVisualStyle.edge(for: theme) }
    var accent: Color { ReaderVisualStyle.accent(for: theme) }
    var fill: Color { surface.opacity(reduceTransparency ? 1 : 0.97) }
    /// A quiet section surface, local to the settings sheet rather than the reading canvas.
    var card: Color { ReaderVisualStyle.sectionSurface(for: theme) }
    var secondary: Color { foreground.opacity(0.76) }
    var selection: Color { foreground.opacity(0.06) }
    var shadow: Color { Color.black.opacity(theme == .dark ? 0.12 : 0.04) }
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
