import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct ReaderToolAppearance {
    let theme: ReaderTheme
    let reduceTransparency: Bool

    var surface: Color { ReaderVisualStyle.surface(for: theme) }
    var elevatedSurface: Color { ReaderVisualStyle.elevatedSurface(for: theme) }
    var foreground: Color { Color(uiColor: theme.foreground) }
    var edge: Color { ReaderVisualStyle.edge(for: theme) }
    var accent: Color { ReaderVisualStyle.accent(for: theme) }
    var accentSoft: Color { accent.opacity(theme == .dark ? 0.18 : 0.11) }
    var sealAccent: Color { ReaderVisualStyle.sealAccent(for: theme) }

    // Opaque local tool paint: softness comes from tone, not canvas text showing through.
    var fill: Color {
        switch theme {
        case .paper: Color(.sRGB, red: 248.0 / 255, green: 245.0 / 255, blue: 236.0 / 255, opacity: 1)
        case .light: Color(.sRGB, red: 248.0 / 255, green: 250.0 / 255, blue: 248.0 / 255, opacity: 1)
        case .dark: Color(.sRGB, red: 36.0 / 255, green: 43.0 / 255, blue: 39.0 / 255, opacity: 1)
        }
    }

    /// A quiet section surface, local to the settings sheet rather than the reading canvas.
    var card: Color { ReaderVisualStyle.sectionSurface(for: theme) }

    var secondary: Color {
        let color = theme.foreground
        return Color(uiColor: UIColor { traits in
            color.withAlphaComponent(traits.accessibilityContrast == .high ? 1 : 0.72)
        })
    }

    // Existing in-label consumers (including TXT) retain their translucent selection paint.
    var selection: Color { accent.opacity(theme == .dark ? 0.18 : 0.11) }
    // Opaque selection behind the ButtonStyle's press feedback.
    var selectedControl: Color { ReaderVisualStyle.selectionSurface(for: theme) }
    var shadow: Color { Color.black.opacity(theme == .dark ? 0.34 : 0.08) }
    var subtleShadow: Color { Color.black.opacity(theme == .dark ? 0.24 : 0.045) }
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
