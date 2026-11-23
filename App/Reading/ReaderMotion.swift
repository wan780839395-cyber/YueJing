import SwiftUI

/// Render-only timing. These values are design parameters, not measured device latency.
@MainActor
enum ReaderMotion {
    static let toolVisibilityDuration: Double = 0.18
    static let selectionFeedbackDuration: Double = 0.16
    static let pressFeedbackDuration: Double = 0.10
    static let hiddenTravel: CGFloat = 8
    // Dock changes structure immediately; only the incoming branch fades, no morph.
    static let dockPresentationDuration: Double = 0.12
    static let tabSwitchDuration: Double = 0.22

    static var toolVisibility: Animation { .easeOut(duration: toolVisibilityDuration) }
    static var selectionFeedback: Animation { .easeOut(duration: selectionFeedbackDuration) }
    static var pressFeedback: Animation { .easeOut(duration: pressFeedbackDuration) }
    static var dockPresentation: Animation { .easeOut(duration: dockPresentationDuration) }
    static var tabSwitch: Animation { .spring(response: 0.28, dampingFraction: 0.86) }
}
