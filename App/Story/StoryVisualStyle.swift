import Foundation
import ReaderDomain
import SwiftUI

/// Resolves a `StoryVisualRecipe` whitelist into concrete native iOS 16.6 SwiftUI
/// colors, typography, atmosphere physics, and surface geometry while guaranteeing
/// high legibility for long-form novel reading.
struct StoryResolvedStyle: Equatable {
    enum PaletteKind: String, CaseIterable {
        case `default` = "default"
        case noirBrass = "noirBrass"
        case inkPaper = "inkPaper"
        case deepOrbit = "deepOrbit"
        case warmAmber = "warmAmber"
        case crimsonMist = "crimsonMist"

        var displayName: String {
            switch self {
            case .default: return "阅境默认"
            case .noirBrass: return "暗夜黄铜"
            case .inkPaper: return "宣纸青墨"
            case .deepOrbit: return "深空冷蓝"
            case .warmAmber: return "暖纸琥珀"
            case .crimsonMist: return "赤雾暗红"
            }
        }
    }

    enum AtmosphereKind: String, CaseIterable {
        case calm = "calm"
        case rainFog = "rainFog"
        case inkPetals = "inkPetals"
        case starOrbit = "starOrbit"
        case warmDust = "warmDust"
        case embers = "embers"

        var displayName: String {
            switch self {
            case .calm: return "静谧柔光"
            case .rainFog: return "斜雨微雾"
            case .inkPetals: return "烟岚落叶"
            case .starOrbit: return "深空星轨"
            case .warmDust: return "暖光浮尘"
            case .embers: return "微火星烬"
            }
        }
    }

    enum TypographyKind: String, CaseIterable {
        case classicSerif = "classicSerif"
        case editorialSans = "editorialSans"
        case calligraphicHeader = "calligraphicHeader"

        var displayName: String {
            switch self {
            case .classicSerif: return "古典书卷"
            case .editorialSans: return "现代冷峻"
            case .calligraphicHeader: return "重墨章名"
            }
        }
    }

    let recipe: StoryVisualRecipe
    let palette: PaletteKind
    let atmosphere: AtmosphereKind
    let typography: TypographyKind

    let isDark: Bool
    let pageBackground: Color
    let surface: Color
    let subtleSurface: Color
    let foreground: Color
    let secondary: Color
    let accent: Color
    let accentSoft: Color
    let sealAccent: Color
    let sealSoft: Color
    let edge: Color

    var isStandard: Bool {
        recipe == .standard
    }

    var shortLabel: String {
        if isStandard {
            return "默认风格"
        }
        return "\(palette.displayName) · \(atmosphere.displayName)"
    }

    var cardCornerRadius: CGFloat {
        switch typography {
        case .editorialSans: return 10
        case .classicSerif: return 18
        case .calligraphicHeader: return 14
        }
    }

    var primaryButtonForeground: Color {
        isDark ? Color.black.opacity(0.92) : Color.white
    }

    var bookTitleFont: Font {
        switch typography {
        case .classicSerif:
            return .system(.title3, design: .serif).weight(.bold)
        case .editorialSans:
            return .system(.title3, design: .default).weight(.bold)
        case .calligraphicHeader:
            return .system(.title2, design: .serif).weight(.heavy)
        }
    }

    var chapterHeadingFont: Font {
        switch typography {
        case .classicSerif:
            return .system(.headline, design: .serif).weight(.bold)
        case .editorialSans:
            return .system(.headline, design: .default).weight(.semibold)
        case .calligraphicHeader:
            return .system(.title3, design: .serif).weight(.bold)
        }
    }

    var proseFont: Font {
        switch typography {
        case .classicSerif, .calligraphicHeader:
            return .system(.body, design: .serif)
        case .editorialSans:
            return .system(.body, design: .default)
        }
    }

    var proseLineSpacing: CGFloat {
        switch typography {
        case .classicSerif: return 9.5
        case .editorialSans: return 7.5
        case .calligraphicHeader: return 10.0
        }
    }

    var colorSchemeOverride: ColorScheme? {
        palette == .default ? nil : (isDark ? .dark : .light)
    }

    static func resolve(recipe: StoryVisualRecipe, base: LibraryAppearance) -> StoryResolvedStyle {
        let p = PaletteKind(rawValue: recipe.palette) ?? .default
        let a = AtmosphereKind(rawValue: recipe.atmosphere) ?? .calm
        let t = TypographyKind(rawValue: recipe.typography) ?? .classicSerif

        switch p {
        case .default:
            return StoryResolvedStyle(
                recipe: recipe,
                palette: p,
                atmosphere: a,
                typography: t,
                isDark: base.isDarkSurface,
                pageBackground: base.page,
                surface: base.surface,
                subtleSurface: base.subtleSurface,
                foreground: base.foreground,
                secondary: base.secondary,
                accent: base.accent,
                accentSoft: base.accentSoft,
                sealAccent: base.sealAccent,
                sealSoft: base.sealSoft,
                edge: base.edge
            )
        case .noirBrass:
            return StoryResolvedStyle(
                recipe: recipe,
                palette: p,
                atmosphere: a,
                typography: t,
                isDark: true,
                pageBackground: Color(red: 0.043, green: 0.071, blue: 0.102),
                surface: Color(red: 0.082, green: 0.129, blue: 0.176),
                subtleSurface: Color(red: 0.118, green: 0.176, blue: 0.231),
                foreground: Color(red: 0.945, green: 0.937, blue: 0.914),
                secondary: Color(red: 0.725, green: 0.745, blue: 0.753),
                accent: Color(red: 0.898, green: 0.718, blue: 0.369),
                accentSoft: Color(red: 0.898, green: 0.718, blue: 0.369).opacity(0.18),
                sealAccent: Color(red: 0.482, green: 0.667, blue: 0.718),
                sealSoft: Color(red: 0.482, green: 0.667, blue: 0.718).opacity(0.18),
                edge: Color(red: 0.898, green: 0.718, blue: 0.369).opacity(0.32)
            )
        case .inkPaper:
            return StoryResolvedStyle(
                recipe: recipe,
                palette: p,
                atmosphere: a,
                typography: t,
                isDark: false,
                pageBackground: Color(red: 0.953, green: 0.933, blue: 0.894),
                surface: Color(red: 0.988, green: 0.976, blue: 0.953),
                subtleSurface: Color(red: 0.918, green: 0.898, blue: 0.855),
                foreground: Color(red: 0.106, green: 0.133, blue: 0.149),
                secondary: Color(red: 0.329, green: 0.376, blue: 0.396),
                accent: Color(red: 0.745, green: 0.231, blue: 0.169),
                accentSoft: Color(red: 0.745, green: 0.231, blue: 0.169).opacity(0.13),
                sealAccent: Color(red: 0.173, green: 0.392, blue: 0.431),
                sealSoft: Color(red: 0.173, green: 0.392, blue: 0.431).opacity(0.14),
                edge: Color(red: 0.173, green: 0.392, blue: 0.431).opacity(0.28)
            )
        case .deepOrbit:
            return StoryResolvedStyle(
                recipe: recipe,
                palette: p,
                atmosphere: a,
                typography: t,
                isDark: true,
                pageBackground: Color(red: 0.024, green: 0.043, blue: 0.086),
                surface: Color(red: 0.055, green: 0.098, blue: 0.176),
                subtleSurface: Color(red: 0.086, green: 0.145, blue: 0.247),
                foreground: Color(red: 0.918, green: 0.965, blue: 1.000),
                secondary: Color(red: 0.659, green: 0.796, blue: 0.914),
                accent: Color(red: 0.267, green: 0.847, blue: 1.000),
                accentSoft: Color(red: 0.267, green: 0.847, blue: 1.000).opacity(0.18),
                sealAccent: Color(red: 1.000, green: 0.616, blue: 0.231),
                sealSoft: Color(red: 1.000, green: 0.616, blue: 0.231).opacity(0.18),
                edge: Color(red: 0.267, green: 0.847, blue: 1.000).opacity(0.34)
            )
        case .warmAmber:
            return StoryResolvedStyle(
                recipe: recipe,
                palette: p,
                atmosphere: a,
                typography: t,
                isDark: false,
                pageBackground: Color(red: 0.984, green: 0.949, blue: 0.890),
                surface: Color(red: 1.000, green: 0.984, blue: 0.957),
                subtleSurface: Color(red: 0.953, green: 0.898, blue: 0.824),
                foreground: Color(red: 0.220, green: 0.141, blue: 0.106),
                secondary: Color(red: 0.451, green: 0.341, blue: 0.278),
                accent: Color(red: 0.831, green: 0.337, blue: 0.424),
                accentSoft: Color(red: 0.831, green: 0.337, blue: 0.424).opacity(0.14),
                sealAccent: Color(red: 0.310, green: 0.580, blue: 0.471),
                sealSoft: Color(red: 0.310, green: 0.580, blue: 0.471).opacity(0.15),
                edge: Color(red: 0.831, green: 0.337, blue: 0.424).opacity(0.26)
            )
        case .crimsonMist:
            return StoryResolvedStyle(
                recipe: recipe,
                palette: p,
                atmosphere: a,
                typography: t,
                isDark: true,
                pageBackground: Color(red: 0.086, green: 0.039, blue: 0.051),
                surface: Color(red: 0.145, green: 0.071, blue: 0.086),
                subtleSurface: Color(red: 0.204, green: 0.106, blue: 0.125),
                foreground: Color(red: 0.969, green: 0.933, blue: 0.925),
                secondary: Color(red: 0.796, green: 0.690, blue: 0.698),
                accent: Color(red: 0.918, green: 0.357, blue: 0.396),
                accentSoft: Color(red: 0.918, green: 0.357, blue: 0.396).opacity(0.20),
                sealAccent: Color(red: 0.910, green: 0.690, blue: 0.420),
                sealSoft: Color(red: 0.910, green: 0.690, blue: 0.420).opacity(0.18),
                edge: Color(red: 0.918, green: 0.357, blue: 0.396).opacity(0.34)
            )
        }
    }

    static let curatedPresets: [(title: String, subtitle: String, recipe: StoryVisualRecipe)] = {
        var list: [(String, String, StoryVisualRecipe)] = [
            ("阅境默认", "跟随系统与书架外观", .standard)
        ]
        if let r = StoryVisualRecipe(palette: "noirBrass", atmosphere: "rainFog", typography: "classicSerif") {
            list.append(("暗夜悬疑", "黄铜雾雨 · 书卷衬线", r))
        }
        if let r = StoryVisualRecipe(palette: "inkPaper", atmosphere: "inkPetals", typography: "calligraphicHeader") {
            list.append(("东方山海", "宣纸青墨 · 重墨章名", r))
        }
        if let r = StoryVisualRecipe(palette: "deepOrbit", atmosphere: "starOrbit", typography: "editorialSans") {
            list.append(("深空科幻", "冷蓝星轨 · 现代无衬线", r))
        }
        if let r = StoryVisualRecipe(palette: "warmAmber", atmosphere: "warmDust", typography: "classicSerif") {
            list.append(("暖灯童话", "暖纸琥珀 · 柔和浮尘", r))
        }
        if let r = StoryVisualRecipe(palette: "crimsonMist", atmosphere: "embers", typography: "calligraphicHeader") {
            list.append(("诡谲赤雾", "暗红星烬 · 肃穆章名", r))
        }
        return list
    }()
}

/// Multi-physics native SwiftUI Canvas driven by `StoryResolvedStyle.atmosphere`.
/// Uses explicit `CGFloat`/`Double` helpers to avoid Swift type-checker timeouts.
struct StoryStyledAtmosphereCanvas: View {
    let style: StoryResolvedStyle
    let pulseToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseStartDate: Date?

    private struct ParticleSeed {
        let x: Double
        let y: Double
        let r: Double
        let speed: Double
        let phase: Double
        let alt: Bool
    }

    private static let seeds: [ParticleSeed] = (0..<32).map { idx in
        let d = Double(idx)
        return ParticleSeed(
            x: (sin(d * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1.0).magnitude,
            y: (sin(d * 78.233) * 19341.123).truncatingRemainder(dividingBy: 1.0).magnitude,
            r: 1.4 + Double(idx % 4) * 0.9,
            speed: 0.012 + Double(idx % 5) * 0.008,
            phase: d * 0.81,
            alt: idx % 3 == 0
        )
    }

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, size in
                    drawFrame(in: context, size: size, time: 0, pulseElapsed: nil)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let elapsed: Double? = pulseStartDate.map { timeline.date.timeIntervalSince($0) }
                    Canvas { context, size in
                        drawFrame(
                            in: context,
                            size: size,
                            time: timeline.date.timeIntervalSinceReferenceDate,
                            pulseElapsed: elapsed
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: pulseToken) { _ in
            guard !reduceMotion else { return }
            pulseStartDate = Date()
        }
    }

    private func drawFrame(in context: GraphicsContext, size: CGSize, time: Double, pulseElapsed: Double?) {
        drawAmbientHalo(in: context, size: size, time: time)

        switch style.atmosphere {
        case .rainFog:
            drawRainFog(in: context, size: size, time: time)
        case .inkPetals:
            drawInkPetals(in: context, size: size, time: time)
        case .starOrbit:
            drawStarOrbit(in: context, size: size, time: time)
        case .warmDust:
            drawWarmDust(in: context, size: size, time: time)
        case .embers:
            drawEmbers(in: context, size: size, time: time)
        case .calm:
            drawCalmMotes(in: context, size: size, time: time)
        }

        if let elapsed = pulseElapsed {
            drawPulseEffect(in: context, size: size, elapsed: elapsed)
        }
    }

    private func drawAmbientHalo(in context: GraphicsContext, size: CGSize, time: Double) {
        let dx: CGFloat = CGFloat(sin(time * 0.20) * 20.0)
        let center = CGPoint(x: size.width * 0.78 + dx, y: size.height * 0.16)
        let radius: CGFloat = max(size.width, size.height) * 0.48
        let a1: Double = style.isDark ? 0.17 : 0.11
        let a2: Double = style.isDark ? 0.06 : 0.04
        let grad = Gradient(colors: [style.accent.opacity(a1), style.sealAccent.opacity(a2), .clear])
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(grad, center: center, startRadius: 6, endRadius: radius))
    }

    private func drawRainFog(in context: GraphicsContext, size: CGSize, time: Double) {
        let fogCenter = CGPoint(x: size.width * 0.25 + CGFloat(sin(time * 0.15) * 35.0), y: size.height * 0.52)
        let fogR: CGFloat = size.width * 0.65
        let fogGrad = Gradient(colors: [style.sealAccent.opacity(0.11), .clear])
        context.fill(
            Path(ellipseIn: CGRect(x: fogCenter.x - fogR, y: fogCenter.y - fogR, width: fogR * 2, height: fogR * 2)),
            with: .radialGradient(fogGrad, center: fogCenter, startRadius: 10, endRadius: fogR)
        )

        var rainPath = Path()
        for s in Self.seeds {
            let fall: Double = (s.y + time * (s.speed * 5.2)).truncatingRemainder(dividingBy: 1.0)
            let x: CGFloat = CGFloat(s.x) * size.width - CGFloat(fall * 28.0)
            let y: CGFloat = CGFloat(fall) * size.height
            let len: CGFloat = CGFloat(10.0 + s.r * 3.5)
            rainPath.move(to: CGPoint(x: x, y: y))
            rainPath.addLine(to: CGPoint(x: x - 3.0, y: y + len))
        }
        context.stroke(rainPath, with: .color(style.secondary.opacity(0.24)), lineWidth: 0.9)
    }

    private func drawInkPetals(in context: GraphicsContext, size: CGSize, time: Double) {
        // Distant ink mountain wash
        var hill = Path()
        hill.move(to: CGPoint(x: 0, y: size.height))
        let step: CGFloat = max(24.0, size.width / 12.0)
        var xPos: CGFloat = 0
        while xPos <= size.width + step {
            let wave: Double = sin(Double(xPos) * 0.01 + time * 0.12) * 20.0
            let yPos: CGFloat = size.height * 0.80 + CGFloat(wave)
            hill.addLine(to: CGPoint(x: xPos, y: yPos))
            xPos += step
        }
        hill.addLine(to: CGPoint(x: size.width, y: size.height))
        hill.closeSubpath()
        context.fill(hill, with: .color(style.sealAccent.opacity(0.08)))

        for s in Self.seeds.prefix(20) {
            let yNorm: Double = (s.y + time * s.speed * 0.8).truncatingRemainder(dividingBy: 1.0)
            let xDrift: CGFloat = CGFloat(sin(time * 0.7 + s.phase) * 22.0)
            let px: CGFloat = CGFloat(s.x) * size.width + xDrift
            let py: CGFloat = CGFloat(yNorm) * size.height
            let w: CGFloat = CGFloat(s.r * 2.8)
            let h: CGFloat = CGFloat(s.r * 0.9)
            let color: Color = s.alt ? style.accent : style.sealAccent
            context.fill(
                Path(ellipseIn: CGRect(x: px - w * 0.5, y: py - h * 0.5, width: w, height: h)),
                with: .color(color.opacity(0.24))
            )
        }
    }

    private func drawStarOrbit(in context: GraphicsContext, size: CGSize, time: Double) {
        let cx: CGFloat = size.width * 0.55
        let cy: CGFloat = size.height * 0.34
        let rx: CGFloat = min(size.width, size.height) * 0.44
        let ry: CGFloat = rx * 0.34
        let orbitRect = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        context.stroke(Path(ellipseIn: orbitRect), with: .color(style.accent.opacity(0.20)), lineWidth: 1.0)

        let satAngle: Double = time * 0.35
        let satX: CGFloat = cx + CGFloat(cos(satAngle)) * rx
        let satY: CGFloat = cy + CGFloat(sin(satAngle)) * ry
        context.fill(
            Path(ellipseIn: CGRect(x: satX - 3.2, y: satY - 3.2, width: 6.4, height: 6.4)),
            with: .color(style.sealAccent.opacity(0.85))
        )

        for s in Self.seeds {
            let twinkle: Double = 0.35 + 0.65 * sin(time * 1.4 + s.phase)
            let px: CGFloat = CGFloat(s.x) * size.width
            let py: CGFloat = CGFloat(s.y) * size.height
            let r: CGFloat = CGFloat(s.r * 0.75)
            let color: Color = s.alt ? style.accent : style.foreground
            context.fill(
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(0.26 * twinkle))
            )
        }
    }

    private func drawWarmDust(in context: GraphicsContext, size: CGSize, time: Double) {
        for s in Self.seeds.prefix(22) {
            let rawY: Double = (s.y - time * s.speed * 0.7).truncatingRemainder(dividingBy: 1.0)
            let normY: Double = rawY < 0 ? rawY + 1.0 : rawY
            let px: CGFloat = CGFloat(s.x) * size.width + CGFloat(sin(time * 0.5 + s.phase) * 16.0)
            let py: CGFloat = CGFloat(normY) * size.height
            let r: CGFloat = CGFloat(s.r * 2.4)
            let color: Color = s.alt ? style.accent : style.sealAccent
            context.fill(
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(0.14))
            )
        }
    }

    private func drawEmbers(in context: GraphicsContext, size: CGSize, time: Double) {
        for s in Self.seeds.prefix(26) {
            let rawY: Double = (s.y - time * s.speed * 1.9).truncatingRemainder(dividingBy: 1.0)
            let normY: Double = rawY < 0 ? rawY + 1.0 : rawY
            let px: CGFloat = CGFloat(s.x) * size.width + CGFloat(sin(time * 1.1 + s.phase) * 18.0)
            let py: CGFloat = CGFloat(normY) * size.height
            let glow: Double = 0.45 + 0.55 * sin(time * 2.2 + s.phase)
            let r: CGFloat = CGFloat(s.r * 0.95)
            let color: Color = s.alt ? style.sealAccent : style.accent
            context.fill(
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(0.36 * glow))
            )
        }
    }

    private func drawCalmMotes(in context: GraphicsContext, size: CGSize, time: Double) {
        let baseAlpha: Double = style.isDark ? 0.16 : 0.10
        for s in Self.seeds.prefix(18) {
            let rawY: Double = (s.y - time * s.speed * 0.5).truncatingRemainder(dividingBy: 1.0)
            let normY: Double = rawY < 0 ? rawY + 1.0 : rawY
            let px: CGFloat = CGFloat(s.x) * size.width + CGFloat(sin(time * 0.45 + s.phase) * 12.0)
            let py: CGFloat = CGFloat(normY) * size.height
            let r: CGFloat = CGFloat(s.r)
            let color: Color = s.alt ? style.sealAccent : style.accent
            context.fill(
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(baseAlpha))
            )
        }
    }

    private func drawPulseEffect(in context: GraphicsContext, size: CGSize, elapsed: Double) {
        let duration: Double = 1.15
        guard elapsed >= 0, elapsed < duration else { return }
        let progress: Double = elapsed / duration
        let eased: Double = 1.0 - pow(1.0 - progress, 3.0)
        let alpha: Double = (1.0 - progress) * (style.isDark ? 0.38 : 0.28)

        switch style.atmosphere {
        case .inkPetals:
            // Sweeping calligraphic slash arc
            var slash = Path()
            let endX: CGFloat = size.width * (0.15 + CGFloat(eased) * 0.72)
            let endY: CGFloat = size.height * (0.72 - CGFloat(eased) * 0.46)
            slash.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.72))
            slash.addLine(to: CGPoint(x: endX, y: endY))
            context.stroke(slash, with: .color(style.accent.opacity(alpha)), lineWidth: CGFloat(5.0 * (1.0 - progress * 0.6)))
        case .rainFog:
            // Subtle warm brass veil flash + ring
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(style.accent.opacity(alpha * 0.22)))
            drawCenterRing(in: context, size: size, eased: eased, alpha: alpha)
        default:
            drawCenterRing(in: context, size: size, eased: eased, alpha: alpha)
        }
    }

    private func drawCenterRing(in context: GraphicsContext, size: CGSize, eased: Double, alpha: Double) {
        let diag: Double = hypot(Double(size.width), Double(size.height))
        let radius: CGFloat = 20.0 + CGFloat(eased * diag * 0.52)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.65)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(style.accent.opacity(alpha)), lineWidth: 2.0)
    }
}

/// Pre-flight confirmation sheet before calling `StoryStyleDirector.generate(draft)`.
/// Freezes and displays exact endpoint, model, billing warning, and full message payload.
@MainActor
struct StoryStyleConfirmSheet: View {
    let draft: StoryStyleDraft
    let appearance: LibraryAppearance
    let onConfirm: (StoryStyleDraft) -> Void
    let onCancel: () -> Void

    @State private var expandedIndices: Set<Int> = []

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("即将由你配置的模型为本局判定视觉风格")
                            .font(.subheadline.weight(.semibold))
                        rowLabel("完整端点", draft.endpoint.absoluteString, mono: true)
                        rowLabel("目标模型", draft.model, mono: true)
                        rowLabel("输出范围", "仅从白名单选择色系、氛围与字族枚举（非可执行代码）", mono: false)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.styleConfirm.summary")

                    if draft.endpoint.scheme?.lowercased() == "http" {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.subheadline)
                                .foregroundStyle(appearance.sealAccent)
                                .accessibilityHidden(true)
                            Text("明文 HTTP 提醒：本次将通过未加密的局域网 HTTP 向 \(draft.endpoint.absoluteString) 发送判型请求并接收结果，同 Wi-Fi 下其他设备可能截获内容及可选 Token。")
                                .font(.caption)
                                .foregroundStyle(appearance.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(appearance.sealAccent.opacity(0.38), lineWidth: 0.8)
                                .allowsHitTesting(false)
                        }
                        .accessibilityIdentifier("story.styleConfirm.plaintextNotice")
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "network")
                            .font(.subheadline)
                            .foregroundStyle(appearance.sealAccent)
                            .accessibilityHidden(true)
                        Text(draft.endpoint.scheme?.lowercased() == "http"
                             ? "确认后将向已授权的局域网电脑服务发起一次真实网络请求；取消不会联网，失败将维持当前风格不变。"
                             : "确认后将向你的 BYOK 接口发起一次真实网络请求并可能产生第三方计费；取消不会联网，失败将维持当前风格不变。")
                            .font(.caption)
                            .foregroundStyle(appearance.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("冻结发送的消息（共 \(draft.messages.count) 条）")
                            .font(LibraryAppearance.sectionTitleFont)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(Array(draft.messages.enumerated()), id: \.offset) { idx, msg in
                            let expanded = expandedIndices.contains(idx)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("#\(idx + 1)").font(.caption2.monospacedDigit()).foregroundStyle(appearance.secondary)
                                    Text(msg.role)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(appearance.accent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(appearance.accentSoft, in: Capsule())
                                    Spacer(minLength: 0)
                                    Text("\(msg.content.count) 字").font(.caption2.monospacedDigit()).foregroundStyle(appearance.secondary)
                                }
                                Button {
                                    if expanded { expandedIndices.remove(idx) } else { expandedIndices.insert(idx) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(msg.content)
                                            .font(.footnote)
                                            .lineSpacing(4)
                                            .foregroundStyle(appearance.foreground)
                                            .lineLimit(expanded ? nil : 3)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if msg.content.count > 90 {
                                            Text(expanded ? "收起" : "展开查看全文")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(appearance.accent)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            }
                            .accessibilityIdentifier("story.styleConfirm.message.\(idx)")
                        }
                    }
                }
                .padding(.horizontal, LibraryAppearance.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        cancelButton
                        confirmButton
                    }
                    VStack(spacing: 8) {
                        confirmButton
                        cancelButton
                    }
                }
                .padding(.horizontal, LibraryAppearance.horizontalInset)
                .padding(.vertical, 12)
                .background(appearance.surface.opacity(0.96))
                .overlay(alignment: .top) {
                    Rectangle().fill(appearance.edge.opacity(0.75)).frame(height: 0.6)
                }
            }
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .navigationTitle("AI 判型发送前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                        .font(AppVisualStyle.actionFont)
                        .foregroundStyle(appearance.secondary)
                }
            }
        }
        .accessibilityIdentifier("story.styleConfirm.sheet")
    }

    private func rowLabel(_ title: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(appearance.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .footnote)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cancelButton: some View {
        Button { onCancel() } label: {
            Text("取消不发送")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.secondary,
            surface: appearance.subtleSurface,
            border: appearance.edge.opacity(0.8),
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.styleConfirm.cancel")
    }

    private var confirmButton: some View {
        Button { onConfirm(draft) } label: {
            Text("确认并由 AI 判型")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: primaryButtonForeground,
            surface: appearance.accent,
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.styleConfirm.send")
    }
}

/// Interactive style comparison & AI style direction control sheet for the current story session.
@MainActor
struct StoryStyleCompareSheet: View {
    @Binding var recipe: StoryVisualRecipe
    let appearance: LibraryAppearance
    let hasModelConfig: Bool
    let isDirectingStyle: Bool
    let styleStatusMessage: String?
    let onRequestAIDirect: () -> Void
    let onCancelAIDirect: () -> Void
    let onOpenModelConfig: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    aiDirectorCard

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("一键视觉对照")
                                .font(LibraryAppearance.sectionTitleFont)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            if recipe != .standard {
                                Button("还原默认") {
                                    StoryHaptics.selection()
                                    recipe = .standard
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(appearance.accent)
                                .accessibilityIdentifier("story.style.reset")
                            }
                        }

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(Array(StoryResolvedStyle.curatedPresets.enumerated()), id: \.offset) { idx, item in
                                let selected = recipe == item.recipe
                                Button {
                                    StoryHaptics.selection()
                                    recipe = item.recipe
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(selected ? appearance.accent : appearance.foreground)
                                        Text(item.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(appearance.secondary)
                                            .lineLimit(2)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                                    .background(
                                        selected ? appearance.accentSoft : appearance.surface,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(selected ? appearance.accent : appearance.edge.opacity(0.75), lineWidth: selected ? 1.3 : 0.75)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("story.style.preset.\(idx)")
                            }
                        }
                    }

                    dimensionSection(
                        title: "色系基底（Palette）",
                        items: StoryResolvedStyle.PaletteKind.allCases.map { ($0.rawValue, $0.displayName) },
                        current: recipe.palette
                    ) { newVal in
                        if let next = StoryVisualRecipe(palette: newVal, atmosphere: recipe.atmosphere, typography: recipe.typography) {
                            StoryHaptics.selection()
                            recipe = next
                        }
                    }

                    dimensionSection(
                        title: "动态氛围（Atmosphere）",
                        items: StoryResolvedStyle.AtmosphereKind.allCases.map { ($0.rawValue, $0.displayName) },
                        current: recipe.atmosphere
                    ) { newVal in
                        if let next = StoryVisualRecipe(palette: recipe.palette, atmosphere: newVal, typography: recipe.typography) {
                            StoryHaptics.selection()
                            recipe = next
                        }
                    }

                    dimensionSection(
                        title: "字族排版（Typography）",
                        items: StoryResolvedStyle.TypographyKind.allCases.map { ($0.rawValue, $0.displayName) },
                        current: recipe.typography
                    ) { newVal in
                        if let next = StoryVisualRecipe(palette: recipe.palette, atmosphere: recipe.atmosphere, typography: newVal) {
                            StoryHaptics.selection()
                            recipe = next
                        }
                    }
                }
                .padding(.horizontal, LibraryAppearance.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .navigationTitle("书境视觉风格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(AppVisualStyle.actionFont)
                        .foregroundStyle(appearance.accent)
                        .accessibilityIdentifier("story.style.close")
                }
            }
        }
        .accessibilityIdentifier("story.style.sheet")
    }

    private var aiDirectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.subheadline)
                    .foregroundStyle(appearance.accent)
                    .accessibilityHidden(true)
                Text("交由自配 AI 判断本局视觉风格")
                    .font(.subheadline.weight(.semibold))
            }
            Text("点击后先展示冻结发送清单并由你确认，不自动联网；AI 仅返回白名单风格参数，仅作用于本局视图预览。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let styleStatusMessage {
                Text(styleStatusMessage)
                    .font(.caption)
                    .foregroundStyle(appearance.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDirectingStyle {
                HStack(spacing: 10) {
                    ProgressView().tint(appearance.accent)
                    Text("正在由模型判定风格…").font(.caption).foregroundStyle(appearance.secondary)
                    Spacer()
                    Button("取消") { onCancelAIDirect() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.sealAccent)
                        .accessibilityIdentifier("story.style.cancelAI")
                }
            } else if hasModelConfig {
                Button {
                    dismiss()
                    onRequestAIDirect()
                } label: {
                    Label("预览清单并让 AI 判型", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(AppControlButtonStyle(
                    foreground: primaryButtonForeground,
                    surface: appearance.accent,
                    cornerRadius: 14
                ))
                .accessibilityIdentifier("story.style.requestAI")
            } else {
                Button {
                    dismiss()
                    onOpenModelConfig()
                } label: {
                    Label("先配置 BYOK 模型后再 AI 判型", systemImage: "key")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(AppControlButtonStyle(
                    foreground: appearance.accent,
                    surface: appearance.accentSoft,
                    border: appearance.accent.opacity(0.3),
                    cornerRadius: 14
                ))
                .accessibilityIdentifier("story.style.needConfig")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                .strokeBorder(appearance.accent.opacity(0.35), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
    }

    private func dimensionSection(
        title: String,
        items: [(id: String, name: String)],
        current: String,
        onPick: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(items, id: \.id) { item in
                    let isSelected = current == item.id
                    Button {
                        onPick(item.id)
                    } label: {
                        Text(item.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? primaryButtonForeground : appearance.foreground)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .padding(.horizontal, 8)
                            .background(
                                isSelected ? appearance.accent : appearance.subtleSurface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.style.dim.\(item.id)")
                }
            }
        }
    }
}
