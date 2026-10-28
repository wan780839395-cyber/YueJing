import ReaderDomain
import SwiftUI
import UIKit

@MainActor
final class ReaderViewportHandle {
    weak var controller: ReaderViewController?
    private var restoration: ReaderViewportRestoration?
    var onNextRestoreIsNavigation = false
    func anchor() -> ReadingAnchor? { controller?.restorableAnchor() ?? restoration?.anchor }
    var interacting: Bool { controller?.interacting ?? false }
    func attach(_ value: ReaderViewController) {
        if let old = controller, old !== value {
            restoration = old.restorationPoint() ?? restoration
            old.detachCallbacks()
        }
        controller = value
    }
    func detach(_ value: ReaderViewController) {
        guard controller === value else { return }
        restoration = value.restorationPoint() ?? restoration; controller = nil
    }
    func restoration(for id: UUID) -> ReaderViewportRestoration? { restoration?.windowID == id ? restoration : nil }
    func applied(_ value: ReaderViewController) { if controller === value { restoration = nil } }
}

@MainActor
struct ReaderViewport: UIViewControllerRepresentable {
    @MainActor final class Coordinator {
        let handle: ReaderViewportHandle
        init(handle: ReaderViewportHandle) { self.handle = handle }
    }
    let window: ReadingWindow?
    let preferences: ReaderPreferences
    let handle: ReaderViewportHandle
    let onAnchor: @MainActor (ReadingAnchor, UUID) -> Void
    let onExtend: @MainActor (ReadingAnchor, UUID) -> Void
    let onWidth: @MainActor (Double) -> Void
    let onSettled: @MainActor (ReadingAnchor, UUID) -> Bool
    let onApplied: @MainActor (UUID) -> Void
    let toolIntent: @MainActor () -> UUID
    let onToolsInteraction: @MainActor (ReadingToolsInteraction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeUIViewController(context: Context) -> ReaderViewController {
        let controller = ReaderViewController()
        handle.attach(controller)
        controller.onAnchor = onAnchor; controller.onExtend = onExtend; controller.onWidth = onWidth
        controller.onSettled = onSettled
        controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction
        return controller
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {
        guard handle.controller === controller else { return }
        controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction
        controller.setTheme(preferences.theme)
        guard let window, controller.window?.id != window.id else { return }
        let navigation = handle.onNextRestoreIsNavigation
        handle.onNextRestoreIsNavigation = false
        controller.apply(window, userNavigation: navigation, restoring: navigation ? nil : handle.restoration(for: window.id))
        handle.applied(controller)
        onApplied(window.id)
    }

    static func dismantleUIViewController(_ controller: ReaderViewController, coordinator: Coordinator) {
        coordinator.handle.detach(controller)
        controller.detachCallbacks()
        // Representable reconstruction is not a route exit. ReaderRouteOwner owns final close.
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
