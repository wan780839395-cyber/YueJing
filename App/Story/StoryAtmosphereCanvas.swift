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
            drawHalo(in: context, size: size, drift: 0)
            for mote in Self.motes.prefix(12) {
                let pt = CGPoint(x: mote.seedX * size.width, y: mote.seedY * size.height)
                let rect = CGRect(x: pt.x - mote.radius, y: pt.y - mote.radius, width: mote.radius * 2, height: mote.radius * 2)
                let color = mote.usesSeal ? appearance.sealAccent : appearance.accent
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(appearance.isDarkSurface ? 0.14 : 0.10)))
            }
        }
    }

    private func animatedBackdrop(date: Date) -> some View {
        Canvas { context, size in
            let t = date.timeIntervalSinceReferenceDate
            drawHalo(in: context, size: size, drift: sin(t * 0.25) * 18)

            for mote in Self.motes {
                let rawY = (mote.seedY - t * mote.speed).truncatingRemainder(dividingBy: 1.0)
                let normY = rawY < 0 ? rawY + 1.0 : rawY
                let x = mote.seedX * size.width + sin(t * 0.6 + mote.phase) * 14
                let y = normY * size.height
                let twinkle = 0.45 + 0.55 * sin(t * 1.1 + mote.phase)
                let baseAlpha = appearance.isDarkSurface ? 0.18 : 0.12
                let color = mote.usesSeal ? appearance.sealAccent : appearance.accent
                let r = mote.radius
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(baseAlpha * twinkle)))
            }

            // Expanding ink/light ripple when a new turn lands
            if let start = rippleStartDate {
                let elapsed = date.timeIntervalSince(start)
                let duration = 1.15
                if elapsed >= 0, elapsed < duration {
                    let progress = elapsed / duration
                    let eased = 1.0 - pow(1.0 - progress, 3.0)
                    let maxRadius = hypot(size.width, size.height) * 0.55
                    let radius = 24 + eased * maxRadius
                    let center = CGPoint(x: size.width * 0.5, y: size.height * 0.72)
                    let ringRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    let alpha = (1.0 - progress) * (appearance.isDarkSurface ? 0.34 : 0.24)
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color(appearance.accent.opacity(alpha)),
                        lineWidth: 2.0 * (1.0 - progress * 0.5)
                    )
                }
            }
        }
    }

    private func drawHalo(in context: GraphicsContext, size: CGSize, drift: Double) {
        let center = CGPoint(x: size.width * 0.78 + drift, y: size.height * 0.18)
        let radius = max(size.width, size.height) * 0.46
        let gradient = Gradient(colors: [
            appearance.accent.opacity(appearance.isDarkSurface ? 0.14 : 0.09),
            appearance.sealAccent.opacity(appearance.isDarkSurface ? 0.05 : 0.03),
            .clear
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
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
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let outerR = min(canvasSize.width, canvasSize.height) * 0.44
            let innerR = outerR * 0.56
            let accent = roleKind == .canon ? appearance.accent : appearance.sealAccent

            let hashVal: UInt = roleName.unicodeScalars.reduce(0) { ($0 &* 31) &+ UInt($1.value) }
            let sides = 5 + Int(hashVal % 4)

            // Outer ring
            let ringRect = CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2)
            context.stroke(Path(ellipseIn: ringRect), with: .color(accent.opacity(0.35)), lineWidth: 1.0)

            // Star polygon
            var path = Path()
            let totalVertices = sides * 2
            for i in 0..<totalVertices {
                let angle = (Double(i) / Double(totalVertices)) * .pi * 2.0 - .pi / 2.0
                let r = i.isMultiple(of: 2) ? outerR * 0.88 : innerR
                let pt = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if i == 0 {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
            }
            path.closeSubpath()
            context.fill(path, with: .color(accent.opacity(0.16)))
            context.stroke(path, with: .color(accent.opacity(0.88)), lineWidth: 1.3)

            // Center core dot
            let dotR: CGFloat = 2.6
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)),
                with: .color(accent)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
