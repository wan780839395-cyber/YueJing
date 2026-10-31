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
    // Opaque local tool paint: softness comes from tone, not canvas text showing through.
    // Shared by the existing header; this changes its paint only, never its geometry.
    var fill: Color {
        switch theme {
        case .paper: Color(.sRGB, red: 239.0 / 255, green: 236.0 / 255, blue: 226.0 / 255, opacity: 1)
        case .light: Color(.sRGB, red: 241.0 / 255, green: 244.0 / 255, blue: 238.0 / 255, opacity: 1)
        case .dark: Color(.sRGB, red: 45.0 / 255, green: 53.0 / 255, blue: 47.0 / 255, opacity: 1)
        }
    }
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
