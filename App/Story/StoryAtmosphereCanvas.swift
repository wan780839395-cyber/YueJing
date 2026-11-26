import ReaderDomain
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight tactile feedback helper for Story interactions.
@MainActor
enum StoryHaptics {
    static func selection() {
        #if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
        #endif
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }
}

/// Native iOS 16.6 SwiftUI ambient canvas for AI Story hub, forge, and theater.
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

    private static let motes: [Mote] = (0..<28).map { idx in
        let d = Double(idx)
        return Mote(
            seedX: (sin(d * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1.0).magnitude,
            seedY: (sin(d * 78.233) * 19341.123).truncatingRemainder(dividingBy: 1.0).magnitude,
            radius: 1.3 + Double(idx % 4) * 0.95,
            speed: 0.007 + Double(idx % 5) * 0.0038,
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
        drawHalos(in: context, size: size, driftX: 0, driftY: 0)
        let alpha: Double = appearance.isDarkSurface ? 0.14 : 0.10
        for mote in Self.motes.prefix(14) {
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
        let driftX: CGFloat = CGFloat(sin(t * 0.22) * 24.0)
        let driftY: CGFloat = CGFloat(cos(t * 0.18) * 14.0)
        drawHalos(in: context, size: size, driftX: driftX, driftY: driftY)

        let baseAlpha: Double = appearance.isDarkSurface ? 0.20 : 0.13
        for mote in Self.motes {
            let rawY: Double = (mote.seedY - t * mote.speed).truncatingRemainder(dividingBy: 1.0)
            let normY: Double = rawY < 0 ? rawY + 1.0 : rawY
            let xOffset: CGFloat = CGFloat(sin(t * 0.55 + mote.phase) * 16.0)
            let x: CGFloat = CGFloat(mote.seedX) * size.width + xOffset
            let y: CGFloat = CGFloat(normY) * size.height
            let twinkle: Double = 0.40 + 0.60 * sin(t * 1.15 + mote.phase)
            let color: Color = mote.usesSeal ? appearance.sealAccent : appearance.accent
            let r: CGFloat = CGFloat(mote.radius)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(baseAlpha * twinkle)))
        }

        if let start = rippleStartDate {
            drawDualRipple(in: context, size: size, elapsed: date.timeIntervalSince(start))
        }
    }

    private func drawDualRipple(in context: GraphicsContext, size: CGSize, elapsed: Double) {
        let duration: Double = 1.25
        guard elapsed >= 0, elapsed < duration else { return }
        let progress: Double = elapsed / duration
        let eased: Double = 1.0 - pow(1.0 - progress, 3.0)
        let diag: Double = hypot(Double(size.width), Double(size.height))
        let maxRadius: CGFloat = CGFloat(diag * 0.58)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.68)

        let radius1: CGFloat = 24.0 + CGFloat(eased) * maxRadius
        let rect1 = CGRect(x: center.x - radius1, y: center.y - radius1, width: radius1 * 2, height: radius1 * 2)
        let baseAlpha: Double = appearance.isDarkSurface ? 0.36 : 0.25
        let alpha1: Double = (1.0 - progress) * baseAlpha
        let width1: CGFloat = CGFloat(2.2 * (1.0 - progress * 0.55))
        context.stroke(
            Path(ellipseIn: rect1),
            with: .color(appearance.accent.opacity(alpha1)),
            lineWidth: width1
        )

        if progress > 0.12 {
            let p2: Double = min(1.0, (progress - 0.12) / 0.88)
            let e2: Double = 1.0 - pow(1.0 - p2, 3.0)
            let radius2: CGFloat = 16.0 + CGFloat(e2) * (maxRadius * 0.78)
            let rect2 = CGRect(x: center.x - radius2, y: center.y - radius2, width: radius2 * 2, height: radius2 * 2)
            let alpha2: Double = (1.0 - p2) * (baseAlpha * 0.65)
            context.stroke(
                Path(ellipseIn: rect2),
                with: .color(appearance.sealAccent.opacity(alpha2)),
                lineWidth: 1.2
            )
        }
    }

    private func drawHalos(in context: GraphicsContext, size: CGSize, driftX: CGFloat, driftY: CGFloat) {
        let primaryCenter = CGPoint(x: size.width * 0.80 + driftX, y: size.height * 0.16 + driftY)
        let primaryRadius: CGFloat = max(size.width, size.height) * 0.48
        let primaryAlpha: Double = appearance.isDarkSurface ? 0.16 : 0.10
        let secondaryAlpha: Double = appearance.isDarkSurface ? 0.06 : 0.04
        let primaryGradient = Gradient(colors: [
            appearance.accent.opacity(primaryAlpha),
            appearance.sealAccent.opacity(secondaryAlpha),
            .clear
        ])
        let rect1 = CGRect(
            x: primaryCenter.x - primaryRadius,
            y: primaryCenter.y - primaryRadius,
            width: primaryRadius * 2,
            height: primaryRadius * 2
        )
        context.fill(
            Path(ellipseIn: rect1),
            with: .radialGradient(primaryGradient, center: primaryCenter, startRadius: 8, endRadius: primaryRadius)
        )

        let lowerCenter = CGPoint(x: size.width * 0.18 - driftX * 0.7, y: size.height * 0.82 - driftY * 0.6)
        let lowerRadius: CGFloat = max(size.width, size.height) * 0.36
        let lowerAlpha: Double = appearance.isDarkSurface ? 0.11 : 0.07
        let lowerGradient = Gradient(colors: [
            appearance.sealAccent.opacity(lowerAlpha),
            .clear
        ])
        let rect2 = CGRect(
            x: lowerCenter.x - lowerRadius,
            y: lowerCenter.y - lowerRadius,
            width: lowerRadius * 2,
            height: lowerRadius * 2
        )
        context.fill(
            Path(ellipseIn: rect2),
            with: .radialGradient(lowerGradient, center: lowerCenter, startRadius: 6, endRadius: lowerRadius)
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
        context.stroke(Path(ellipseIn: ringRect), with: .color(accent.opacity(0.38)), lineWidth: 1.0)

        let star = starPath(
            center: center,
            outerRadius: outerR * 0.88,
            innerRadius: innerR,
            sides: vertexSides
        )
        context.fill(star, with: .color(accent.opacity(0.18)))
        context.stroke(star, with: .color(accent.opacity(0.90)), lineWidth: 1.35)

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

/// Animated living sigil with orbital halo & reactive spring twist on name/role change.
struct StoryLivingSigilView: View {
    let roleKind: StoryRoleKind
    let roleName: String
    let appearance: LibraryAppearance
    var size: CGFloat = 68

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false
    @State private var reactionAngle: Double = 0

    private var accentColor: Color {
        roleKind == .canon ? appearance.accent : appearance.sealAccent
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            accentColor.opacity(appearance.isDarkSurface ? 0.28 : 0.18),
                            accentColor.opacity(0.02)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.62
                    )
                )
                .frame(width: size * 1.24, height: size * 1.24)
                .scaleEffect(reduceMotion ? 1.0 : (isBreathing ? 1.08 : 0.94))

            Circle()
                .strokeBorder(
                    accentColor.opacity(0.32),
                    style: StrokeStyle(lineWidth: 0.85, dash: [4, 4])
                )
                .frame(width: size * 1.06, height: size * 1.06)
                .rotationEffect(.degrees(reduceMotion ? 0 : (isBreathing ? 45 : 0)))

            StorySoulSigilView(
                roleKind: roleKind,
                roleName: roleName.isEmpty ? "阅境" : roleName,
                appearance: appearance,
                size: size
            )
            .rotationEffect(.degrees(reduceMotion ? 0 : reactionAngle))
        }
        .frame(width: size * 1.24, height: size * 1.24)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
        .onChange(of: roleKind) { _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                reactionAngle += 36
            }
        }
        .onChange(of: roleName.count) { _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                reactionAngle += 14
            }
        }
    }
}

/// Subtle sweeping border highlight for hero story portal cards.
struct StoryShimmerBorder: View {
    let cornerRadius: CGFloat
    let appearance: LibraryAppearance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                staticStroke
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let t: Double = timeline.date.timeIntervalSinceReferenceDate
                    let angle: Angle = .degrees((t * 28.0).truncatingRemainder(dividingBy: 360.0))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    appearance.accent.opacity(0.18),
                                    appearance.accent.opacity(0.72),
                                    appearance.sealAccent.opacity(0.45),
                                    appearance.accent.opacity(0.16)
                                ]),
                                center: .center,
                                angle: angle
                            ),
                            lineWidth: 1.25
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var staticStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        appearance.accent.opacity(0.55),
                        appearance.sealAccent.opacity(0.32),
                        appearance.edge.opacity(0.6)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.15
            )
    }
}
