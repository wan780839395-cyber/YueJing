import SwiftUI

/// Keeps the label's hit target intact; pure-icon controls default to a 6pt surface inset,
/// while text controls can opt into a non-inset outlined enclosure around padded content.
@MainActor
struct ReaderCompactButtonStyle: ButtonStyle {
    let tint: Color
    var surfaceInset: CGFloat = 6
    var outlined: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let animatePress = isEnabled && !reduceMotion
        return configuration.label
            .foregroundStyle(tint)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .inset(by: surfaceInset)
                shape
                    .fill(tint.opacity(pressed ? 0.18 : 0.08))
                    .overlay {
                        if outlined {
                            shape.strokeBorder(tint.opacity(pressed ? 0.36 : 0.22), lineWidth: 0.8)
                        }
                    }
                    .animation(animatePress ? ReaderMotion.pressFeedback : nil,
                               value: animatePress ? (pressed ? 1 : 2) : 0)
                    .transaction { transaction in
                        if !animatePress { transaction.animation = nil }
                    }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}
