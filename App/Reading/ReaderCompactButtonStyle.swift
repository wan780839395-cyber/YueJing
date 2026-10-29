import SwiftUI

/// Keeps the label's hit target intact; only the visible surface is inset.
@MainActor
struct ReaderCompactButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let animatePress = isEnabled && !reduceMotion
        return configuration.label
            .foregroundStyle(tint)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .inset(by: 6)
                    .fill(tint.opacity(pressed ? 0.18 : 0.08))
                    .animation(animatePress ? ReaderMotion.pressFeedback : nil,
                               value: animatePress ? (pressed ? 1 : 2) : 0)
                    .transaction { transaction in
                        if !animatePress { transaction.animation = nil }
                    }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}
