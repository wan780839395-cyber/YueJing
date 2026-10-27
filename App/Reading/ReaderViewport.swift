import ReaderDomain
import SwiftUI
import UIKit

@MainActor
final class ReaderViewportHandle {
    weak var controller: ReaderViewController?
    var onNextRestoreIsNavigation = false
    func anchor() -> ReadingAnchor? { controller?.restorableAnchor() }
    var interacting: Bool { controller?.interacting ?? false }
}

@MainActor
struct ReaderViewport: UIViewControllerRepresentable {
    let window: ReadingWindow?
    let preferences: ReaderPreferences
    let handle: ReaderViewportHandle
    let onAnchor: @MainActor (ReadingAnchor) -> Void
    let onExtend: @MainActor (ReadingAnchor) -> Void
    let onWidth: @MainActor (Double) -> Void
    let onSettled: @MainActor (ReadingAnchor) -> Bool
    let onRemoved: @MainActor () -> Void

    func makeUIViewController(context: Context) -> ReaderViewController {
        let controller = ReaderViewController()
        handle.controller = controller
        controller.onAnchor = onAnchor; controller.onExtend = onExtend; controller.onWidth = onWidth
        controller.onSettled = onSettled
        controller.onRemoved = onRemoved
        return controller
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {
        controller.setTheme(preferences.theme)
        guard let window, controller.window?.id != window.id else { return }
        let navigation = handle.onNextRestoreIsNavigation
        handle.onNextRestoreIsNavigation = false
        controller.apply(window, userNavigation: navigation)
    }

    static func dismantleUIViewController(_ controller: ReaderViewController, coordinator: ()) {
        controller.onRemoved?()
    }
}

@MainActor
extension ReaderTheme {
    var background: UIColor {
        switch self { case .paper: UIColor(red: 0.96, green: 0.94, blue: 0.87, alpha: 1)
        case .light: .white; case .dark: UIColor(white: 0.09, alpha: 1) }
    }
    var foreground: UIColor { self == .dark ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.12, alpha: 1) }
}
