import ReaderDomain
import SwiftUI

/// Native iOS 16.6 SwiftUI ambient canvas for the AI Story theater.
/// Adapts to `LibraryAppearance` and respects `accessibilityReduceMotion`.
struct StoryAtmosphereCanvas: View {
    let appearance: LibraryAppearance
    let pulseToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rippleStartDate: Date?

    private struct Mote {
        let seedX: Double
        let seedY: Double
        let radius: Double
        let speed: Double
        let phase: Double
        let usesSeal: Bool
    }

    private static let motes: [Mote] = (0..<24).map { idx in
        let d = Double(idx)
        return Mote(
            seedX: (sin(d * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1.0).magnitude,
            seedY: (sin(d * 78.233) * 19341.123).truncatingRemainder(dividingBy: 1.0).magnitude,
            radius: 1.4 + Double(idx % 4) * 0.9,
            speed: 0.008 + Double(idx % 5) * 0.004,
            phase: d * 0.73,
            usesSeal: idx % 3 == 0
        )
    }

    var body: some View {
        Group {
            if reduceMotion {
                staticBackdrop
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    animatedBackdrop(date: timeline.date)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: pulseToken) { _ in
            guard !reduceMotion else { return }
            rippleStartDate = Date()
        }
    }

    private var staticBackdrop: some View {
        Canvas { context, size in
            drawStaticBackdrop(in: context, size: size)
        }
    }

    private func animatedBackdrop(date: Date) -> some View {
        Canvas { context, size in
            drawAnimatedBackdrop(in: context, size: size, date: date)
        }
    }

    private func drawStaticBackdrop(in context: GraphicsContext, size: CGSize) {
        drawHalo(in: context, size: size, drift: 0)
        let alpha: Double = appearance.isDarkSurface ? 0.14 : 0.10
        for mote in Self.motes.prefix(12) {
            let x: CGFloat = CGFloat(mote.seedX) * size.width
            let y: CGFloat = CGFloat(mote.seedY) * size.height
            let r: CGFloat = CGFloat(mote.radius)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            let color: Color = mote.usesSeal ? appearance.sealAccent : appearance.accent
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
        }
    }

    private func drawAnimatedBackdrop(in context: GraphicsContext, size: CGSize, date: Date) {
        let t: Double = date.timeIntervalSinceReferenceDate
        let drift: CGFloat = CGFloat(sin(t * 0.25) * 18.0)
        drawHalo(in: context, size: size, drift: drift)

        let baseAlpha: Double = appearance.isDarkSurface ? 0.18 : 0.12
        for mote in Self.motes {
            let rawY: Double = (mote.seedY - t * mote.speed).truncatingRemainder(dividingBy: 1.0)
            let normY: Double = rawY < 0 ? rawY + 1.0 : rawY
            let xOffset: CGFloat = CGFloat(sin(t * 0.6 + mote.phase) * 14.0)
            let x: CGFloat = CGFloat(mote.seedX) * size.width + xOffset
            let y: CGFloat = CGFloat(normY) * size.height
            let twinkle: Double = 0.45 + 0.55 * sin(t * 1.1 + mote.phase)
            let color: Color = mote.usesSeal ? appearance.sealAccent : appearance.accent
            let r: CGFloat = CGFloat(mote.radius)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(baseAlpha * twinkle)))
        }

        if let start = rippleStartDate {
            drawRipple(in: context, size: size, elapsed: date.timeIntervalSince(start))
        }
    }

    private func drawRipple(in context: GraphicsContext, size: CGSize, elapsed: Double) {
        let duration: Double = 1.15
        guard elapsed >= 0, elapsed < duration else { return }
        let progress: Double = elapsed / duration
        let eased: Double = 1.0 - pow(1.0 - progress, 3.0)
        let diag: Double = hypot(Double(size.width), Double(size.height))
        let maxRadius: CGFloat = CGFloat(diag * 0.55)
        let radius: CGFloat = 24.0 + CGFloat(eased) * maxRadius
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.72)
        let ringRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let baseAlpha: Double = appearance.isDarkSurface ? 0.34 : 0.24
        let alpha: Double = (1.0 - progress) * baseAlpha
        let strokeWidth: CGFloat = CGFloat(2.0 * (1.0 - progress * 0.5))
        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(appearance.accent.opacity(alpha)),
            lineWidth: strokeWidth
        )
    }

    private func drawHalo(in context: GraphicsContext, size: CGSize, drift: CGFloat) {
        let center = CGPoint(x: size.width * 0.78 + drift, y: size.height * 0.18)
        let radius: CGFloat = max(size.width, size.height) * 0.46
        let accentAlpha: Double = appearance.isDarkSurface ? 0.14 : 0.09
        let sealAlpha: Double = appearance.isDarkSurface ? 0.05 : 0.03
        let gradient = Gradient(colors: [
            appearance.accent.opacity(accentAlpha),
            appearance.sealAccent.opacity(sealAlpha),
            .clear
        ])
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(gradient, center: center, startRadius: 8, endRadius: radius)
        )
    }
}

/// Deterministic geometric role emblem derived from role kind & name.
struct StorySoulSigilView: View {
    let roleKind: StoryRoleKind
    let roleName: String
    let appearance: LibraryAppearance
    var size: CGFloat = 46

    var body: some View {
        Canvas { context, canvasSize in
            drawSigil(in: context, canvasSize: canvasSize)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var accentColor: Color {
        roleKind == .canon ? appearance.accent : appearance.sealAccent
    }

    private var vertexSides: Int {
        let hashVal: UInt = roleName.unicodeScalars.reduce(0) { ($0 &* 31) &+ UInt($1.value) }
        return 5 + Int(hashVal % 4)
    }

    private func drawSigil(in context: GraphicsContext, canvasSize: CGSize) {
        let center = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        let outerR: CGFloat = min(canvasSize.width, canvasSize.height) * 0.44
        let innerR: CGFloat = outerR * 0.56
        let accent: Color = accentColor

        let ringRect = CGRect(
            x: center.x - outerR,
            y: center.y - outerR,
            width: outerR * 2,
            height: outerR * 2
        )
        context.stroke(Path(ellipseIn: ringRect), with: .color(accent.opacity(0.35)), lineWidth: 1.0)

        let star = starPath(
            center: center,
            outerRadius: outerR * 0.88,
            innerRadius: innerR,
            sides: vertexSides
        )
        context.fill(star, with: .color(accent.opacity(0.16)))
        context.stroke(star, with: .color(accent.opacity(0.88)), lineWidth: 1.3)

        let dotR: CGFloat = 2.6
        let dotRect = CGRect(
            x: center.x - dotR,
            y: center.y - dotR,
            width: dotR * 2,
            height: dotR * 2
        )
        context.fill(Path(ellipseIn: dotRect), with: .color(accent))
    }

    private func starPath(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, sides: Int) -> Path {
        var path = Path()
        let totalVertices: Int = sides * 2
        for index in 0..<totalVertices {
            let fraction: Double = Double(index) / Double(totalVertices)
            let angle: Double = fraction * Double.pi * 2.0 - Double.pi * 0.5
            let radius: CGFloat = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let dx: CGFloat = CGFloat(cos(angle)) * radius
            let dy: CGFloat = CGFloat(sin(angle)) * radius
            let point = CGPoint(x: center.x + dx, y: center.y + dy)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
