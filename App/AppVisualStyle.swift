import SwiftUI

/// Management UI only. Raw values and storage are unrelated to reading preferences.
enum AppAppearance: String, CaseIterable, Sendable {
    case clear = "clear"
    case mist = "mist"
    case ink = "ink"

    static let storageKey = "dev.yuejing.ui.appAppearance.v1"
    static let defaultAppearance: AppAppearance = .mist

    static func restored(from rawValue: String) -> AppAppearance {
        AppAppearance(rawValue: rawValue) ?? defaultAppearance
    }

    var title: String {
        switch self {
        case .clear: "清朗"
        case .mist: "柔雾"
        case .ink: "墨夜"
        }
    }
}

/// Local, immutable UI tokens; no service, environment singleton or reader state.
@MainActor
struct AppVisualStyle {
    let appearance: AppAppearance
    let colorScheme: ColorScheme

    static let minimumControlHeight: CGFloat = 44
    static let compactSpacing: CGFloat = 8
    static let dividerHeight: CGFloat = 0.5
    static var pageTitleFont: Font { .system(.largeTitle, design: .serif).weight(.medium) }
    static var bookTitleFont: Font { .system(.title3, design: .serif).weight(.medium) }
    static var panelTitleFont: Font { .system(.title, design: .serif).weight(.medium) }
    static var actionFont: Font { .subheadline.weight(.medium) }

    // Ink is an explicitly dark management palette, not a forced app color scheme.
    var controlColorScheme: ColorScheme { appearance == .ink ? .dark : colorScheme }

    var page: Color { color(palette.page) }
    var surface: Color { color(palette.surface) }
    var foreground: Color { color(palette.foreground) }
    var secondary: Color { color(palette.secondary) }
    var edge: Color { color(palette.edge) }
    var accent: Color { color(palette.accent) }
    var coverSurface: Color { color(palette.cover) }

    private struct Palette {
        let page: UInt32
        let surface: UInt32
        let foreground: UInt32
        let secondary: UInt32
        let edge: UInt32
        let accent: UInt32
        let cover: UInt32
    }

    private var palette: Palette {
        switch (appearance, colorScheme) {
        case (.clear, .light):
            Palette(page: 0xF4F7FA, surface: 0xFFFFFF, foreground: 0x24323E,
                    secondary: 0x566B7A, edge: 0xCCD8E1, accent: 0x2E6083, cover: 0xE0EAF0)
        case (.clear, _):
            Palette(page: 0x19232D, surface: 0x24323E, foreground: 0xE4ECF3,
                    secondary: 0xB0C2D0, edge: 0x43596A, accent: 0xA4CBE8, cover: 0x314859)
        case (.mist, .light):
            Palette(page: 0xF1EEE8, surface: 0xFAF8F3, foreground: 0x2C3330,
                    secondary: 0x5D6862, edge: 0xD1D6CD, accent: 0x42695B, cover: 0xDCE3DA)
        case (.mist, _):
            Palette(page: 0x222823, surface: 0x303830, foreground: 0xE5E7DE,
                    secondary: 0xB8C1B3, edge: 0x4C594C, accent: 0xB4CDBA, cover: 0x3B4A3D)
        case (.ink, _):
            Palette(page: 0x172027, surface: 0x202C33, foreground: 0xE2E8E7,
                    secondary: 0xB1BFBE, edge: 0x415458, accent: 0x9CCBC3, cover: 0x31484B)
        }
    }

    private func color(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

/// Paint feedback only; the label owns its in-bounds 44pt target and row geometry.
@MainActor
struct AppControlButtonStyle: ButtonStyle {
    let foreground: Color
    var surface: Color = .clear
    var cornerRadius: CGFloat = 22
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let animatePress = isEnabled && !reduceMotion
        return configuration.label
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(foreground.opacity(pressed ? 0.08 : 0))
                    }
                    .allowsHitTesting(false)
                    .animation(animatePress ? .easeOut(duration: 0.10) : nil, value: pressed)
                    .transaction { if !animatePress { $0.animation = nil } }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}
