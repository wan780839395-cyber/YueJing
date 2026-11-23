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

    var subtitle: String {
        switch self {
        case .clear: "天青晴岚 · 澄净通透"
        case .mist: "宣纸松烟 · 温润静谧"
        case .ink: "砚台松墨 · 沉浸夜读"
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
    static var pageTitleFont: Font { .system(.largeTitle, design: .serif).weight(.semibold) }
    static var sectionTitleFont: Font { .system(.title3, design: .serif).weight(.semibold) }
    static var bookTitleFont: Font { .system(.headline, design: .serif).weight(.semibold) }
    static var heroBookTitleFont: Font { .system(.title2, design: .serif).weight(.semibold) }
    static var panelTitleFont: Font { .system(.title2, design: .serif).weight(.semibold) }
    static var actionFont: Font { .subheadline.weight(.medium) }

    // Ink is an explicitly dark management palette, not a forced app color scheme.
    var controlColorScheme: ColorScheme { appearance == .ink ? .dark : colorScheme }
    var isDarkSurface: Bool { controlColorScheme == .dark }

    var page: Color { color(palette.page) }
    var surface: Color { color(palette.surface) }
    var elevatedSurface: Color { color(palette.elevated) }
    var subtleSurface: Color { color(palette.subtle) }
    var foreground: Color { color(palette.foreground) }
    var secondary: Color { color(palette.secondary) }
    var edge: Color { color(palette.edge) }
    var accent: Color { color(palette.accent) }
    var accentSoft: Color { accent.opacity(isDarkSurface ? 0.18 : 0.11) }
    var sealAccent: Color { color(palette.seal) }
    var sealSoft: Color { sealAccent.opacity(isDarkSurface ? 0.18 : 0.10) }
    var coverSurface: Color { color(palette.cover) }
    var shadow: Color { Color.black.opacity(isDarkSurface ? 0.30 : 0.06) }
    var cardShadow: Color { Color.black.opacity(isDarkSurface ? 0.24 : 0.045) }

    private struct Palette {
        let page: UInt32
        let surface: UInt32
        let elevated: UInt32
        let subtle: UInt32
        let foreground: UInt32
        let secondary: UInt32
        let edge: UInt32
        let accent: UInt32
        let seal: UInt32
        let cover: UInt32
    }

    private var palette: Palette {
        switch (appearance, colorScheme) {
        case (.clear, .light):
            Palette(
                page: 0xF3F6FA, surface: 0xFFFFFF, elevated: 0xFFFFFF, subtle: 0xE7EEF5,
                foreground: 0x182532, secondary: 0x526576, edge: 0xCCD8E4,
                accent: 0x205A8D, seal: 0xB36A36, cover: 0xDDE7F0
            )
        case (.clear, _):
            Palette(
                page: 0x121921, surface: 0x1B2531, elevated: 0x233040, subtle: 0x16202B,
                foreground: 0xE8F0F7, secondary: 0x9FB4C6, edge: 0x324557,
                accent: 0x8CC3EE, seal: 0xE19D67, cover: 0x26384A
            )
        case (.mist, .light):
            Palette(
                page: 0xF4EFE6, surface: 0xFCFBF7, elevated: 0xFFFFFF, subtle: 0xEAE3D6,
                foreground: 0x1E2622, secondary: 0x56645D, edge: 0xD6CFC2,
                accent: 0x2B6A56, seal: 0xB5483A, cover: 0xDDD8CC
            )
        case (.mist, _):
            Palette(
                page: 0x161B18, surface: 0x202823, elevated: 0x2A342E, subtle: 0x1B221E,
                foreground: 0xEAECE6, secondary: 0xA6B3A9, edge: 0x39473E,
                accent: 0x8AC7AE, seal: 0xDE7A6B, cover: 0x2E3A33
            )
        case (.ink, _):
            Palette(
                page: 0x10161A, surface: 0x192228, elevated: 0x222E36, subtle: 0x141C21,
                foreground: 0xE8EFEF, secondary: 0x9EB0B2, edge: 0x31434A,
                accent: 0x7EC9BE, seal: 0xDD7B6A, cover: 0x26373D
            )
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
    var border: Color = .clear
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
                            .fill(foreground.opacity(pressed ? 0.09 : 0))
                    }
                    .overlay {
                        if border != .clear {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(border, lineWidth: 0.75)
                        }
                    }
                    .allowsHitTesting(false)
                    .animation(animatePress ? .easeOut(duration: 0.10) : nil, value: pressed)
                    .transaction { if !animatePress { $0.animation = nil } }
            }
            .opacity(isEnabled ? 1 : 0.42)
    }
}

/// Custom-drawn YueJing arch & open-folio brand emblem; purely decorative.
@MainActor
struct YueJingBrandMark: View {
    let tint: Color
    let sealTint: Color
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.11))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.75)
            Path { path in
                let s = size / 24.0
                // Outer study doorway arch
                path.move(to: CGPoint(x: 4.5 * s, y: 18.5 * s))
                path.addLine(to: CGPoint(x: 4.5 * s, y: 8.5 * s))
                path.addQuadCurve(to: CGPoint(x: 9.0 * s, y: 4.5 * s), control: CGPoint(x: 4.5 * s, y: 4.5 * s))
                path.addLine(to: CGPoint(x: 15.0 * s, y: 4.5 * s))
                path.addQuadCurve(to: CGPoint(x: 19.5 * s, y: 8.5 * s), control: CGPoint(x: 19.5 * s, y: 4.5 * s))
                path.addLine(to: CGPoint(x: 19.5 * s, y: 18.5 * s))
                // Open book pages inside arch
                path.move(to: CGPoint(x: 7.5 * s, y: 11.2 * s))
                path.addQuadCurve(to: CGPoint(x: 12.0 * s, y: 12.6 * s), control: CGPoint(x: 10.2 * s, y: 11.0 * s))
                path.addQuadCurve(to: CGPoint(x: 16.5 * s, y: 11.2 * s), control: CGPoint(x: 13.8 * s, y: 11.0 * s))
                path.addLine(to: CGPoint(x: 16.5 * s, y: 17.8 * s))
                path.addQuadCurve(to: CGPoint(x: 12.0 * s, y: 19.0 * s), control: CGPoint(x: 13.8 * s, y: 17.6 * s))
                path.addQuadCurve(to: CGPoint(x: 7.5 * s, y: 17.8 * s), control: CGPoint(x: 10.2 * s, y: 17.6 * s))
                path.closeSubpath()
                // Center spine fold
                path.move(to: CGPoint(x: 12.0 * s, y: 12.6 * s))
                path.addLine(to: CGPoint(x: 12.0 * s, y: 19.0 * s))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: max(1.15, size * 0.055), lineCap: .round, lineJoin: .round))
            Circle()
                .fill(sealTint)
                .frame(width: max(2.8, size * 0.13), height: max(2.8, size * 0.13))
                .offset(y: -size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
