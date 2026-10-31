import SwiftUI

/// Geometry is independent of paint: quiet actions have no persistent surface.
enum ReaderControlRole: Equatable {
    case quiet, primary
}

/// Only the local fill animates; the label and its >=44pt hit bounds never animate.
@MainActor
struct ReaderCompactButtonStyle: ButtonStyle {
    let tint: Color
    var role: ReaderControlRole = .quiet
    @Environment(\.isEnabled) private var isEnabled
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let animatePress = isEnabled && !reduceMotion
        return configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .foregroundStyle(tint)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(pressed ? 0.10 : (role == .primary ? 0.06 : 0)))
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
