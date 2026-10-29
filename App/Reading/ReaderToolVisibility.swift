import SwiftUI

/// The caller keeps visibility, interaction gates, focus, geometry and all actions.
@MainActor
struct ReaderToolVisibility: ViewModifier {
    let visible: Bool
    let hiddenOffset: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            // Do not inherit the reveal animation into child text, frames or layout.
            .transaction { transaction in transaction.animation = nil }
            .opacity(visible ? 1 : 0)
            .offset(y: reduceMotion || visible ? 0 : hiddenOffset)
            .animation(reduceMotion ? nil : ReaderMotion.toolVisibility,
                       value: reduceMotion ? 0 : (visible ? 1 : 2))
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
    }
}
