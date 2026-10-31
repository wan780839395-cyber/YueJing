import SwiftUI

/// The label, visible surface and interaction shape share one >=44pt enclosure.
/// Callers provide content spacing; no invisible inset or expanded row target.
@MainActor
struct ReaderCompactButtonStyle: ButtonStyle {
    let tint: Color
    var outlined: Bool = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Keep the legacy zero-inset panel call site source-compatible; geometry is never inset.
    init(tint: Color, surfaceInset _: CGFloat = 0, outlined: Bool = true) {
        self.tint = tint
        self.outlined = outlined
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let animatePress = isEnabled && !reduceMotion
        return configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(tint)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape
                    .fill(tint.opacity(pressed ? 0.18 : 0.08))
                    .overlay {
                        if outlined {
                            shape.strokeBorder(tint.opacity(pressed ? 0.36 : 0.22), lineWidth: 0.8)
                        }
                    }
                    .allowsHitTesting(false)
                    .animation(animatePress ? ReaderMotion.pressFeedback : nil,
                               value: animatePress ? (pressed ? 1 : 2) : 0)
                    .transaction { transaction in
                        if !animatePress { transaction.animation = nil }
                    }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}
