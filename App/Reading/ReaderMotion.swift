import SwiftUI

/// Render-only timing. These values are design parameters, not measured device latency.
@MainActor
enum ReaderMotion {
    static let toolVisibilityDuration: Double = 0.16
    static let selectionFeedbackDuration: Double = 0.14
    static let pressFeedbackDuration: Double = 0.10
    static let hiddenTravel: CGFloat = 6

    static var toolVisibility: Animation { .easeOut(duration: toolVisibilityDuration) }
    static var selectionFeedback: Animation { .easeOut(duration: selectionFeedbackDuration) }
    static var pressFeedback: Animation { .easeOut(duration: pressFeedbackDuration) }
}
