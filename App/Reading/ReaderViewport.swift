import ReaderDomain
import SwiftUI
import UIKit

@MainActor
final class ReaderViewportHandle {
    weak var controller: ReaderViewController?
    private var restoration: ReaderViewportRestoration?
    private(set) var interactionActive = true
    // BEGIN READER DIAGNOSTICS scene bridge
    private var diagnosticScene: ReaderInteractionDiagnostics.Scene = .unknown
    private weak var diagnosticDelivery: ReaderViewController?
    var diagnosticCallbackObservation: ReaderInteractionDiagnostics? {
        guard let controller, diagnosticDelivery === controller else { return nil }
        return controller.interactionDiagnostics
    }
    func beginDiagnosticDelivery(_ value: ReaderViewController) { diagnosticDelivery = value }
    func endDiagnosticDelivery(_ value: ReaderViewController) {
        if diagnosticDelivery === value { diagnosticDelivery = nil }
    }
    func observeDiagnosticScene(_ phase: ScenePhase) {
        switch phase {
        case .active: diagnosticScene = .active
        case .inactive: diagnosticScene = .inactive
        case .background: diagnosticScene = .background
        @unknown default: diagnosticScene = .unknown
        }
        controller?.interactionDiagnostics.observeScene(diagnosticScene)
    }
    // END READER DIAGNOSTICS scene bridge
    func setInteractionActive(_ active: Bool) {
        // BEGIN READER DIAGNOSTICS handle phase
        controller?.interactionDiagnostics.handlePhase(active, current: controller != nil)
        // END READER DIAGNOSTICS handle phase
        guard interactionActive != active else { return }
        interactionActive = active
        controller?.setInteractionActive(active)
    }
    var onNextRestoreIsNavigation = false
    func anchor() -> ReadingAnchor? { controller?.restorableAnchor() ?? restoration?.anchor }
    var interacting: Bool { controller?.interacting ?? false }
    func attach(_ value: ReaderViewController) {
        // BEGIN READER DIAGNOSTICS replacement
        let diagnosticReplacement = controller != nil && controller !== value
        // END READER DIAGNOSTICS replacement
        if let old = controller, old !== value {
            restoration = old.restorationPoint() ?? restoration
            // BEGIN READER DIAGNOSTICS old detach
            old.interactionDiagnostics.detached()
            // END READER DIAGNOSTICS old detach
            old.detachCallbacks()
        }
        controller = value
        // BEGIN READER DIAGNOSTICS attach
        value.diagnosticHandle = self
        value.interactionDiagnostics.attach(scene: diagnosticScene, replacing: diagnosticReplacement)
        value.interactionDiagnostics.handlePhase(interactionActive, current: controller === value)
        // END READER DIAGNOSTICS attach
        value.setInteractionActive(interactionActive)
    }
    func detach(_ value: ReaderViewController) {
        // BEGIN READER DIAGNOSTICS detach owner
        value.interactionDiagnostics.observeOwner(controller === value)
        // END READER DIAGNOSTICS detach owner
        guard controller === value else { return }
        restoration = value.restorationPoint() ?? restoration; controller = nil
        // BEGIN READER DIAGNOSTICS detached
        value.interactionDiagnostics.detached()
        // END READER DIAGNOSTICS detached
        value.detachCallbacks()
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
    let interactionActive: Bool
    // BEGIN READER DIAGNOSTICS screen snapshot input
    let diagnosticTools: ReadingToolsPresentation
    let diagnosticLoading: Bool
    let diagnosticSaveFailed: Bool
    let diagnosticScene: ScenePhase
    // END READER DIAGNOSTICS screen snapshot input
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
        // BEGIN READER DIAGNOSTICS initial scene
        handle.observeDiagnosticScene(diagnosticScene)
        // END READER DIAGNOSTICS initial scene
        handle.setInteractionActive(interactionActive)
        handle.attach(controller)
        controller.onAnchor = onAnchor; controller.onExtend = onExtend; controller.onWidth = onWidth
        controller.onSettled = onSettled
        controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction
        // BEGIN READER DIAGNOSTICS initial screen facts
        controller.interactionDiagnostics.screenFacts(window: window != nil, loading: diagnosticLoading,
            saveFailed: diagnosticSaveFailed, tools: diagnosticTools)
        // END READER DIAGNOSTICS initial screen facts
        return controller
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {
        // BEGIN READER DIAGNOSTICS update owner
        controller.interactionDiagnostics.observeOwner(handle.controller === controller)
        // END READER DIAGNOSTICS update owner
        guard handle.controller === controller else { return }
        handle.setInteractionActive(interactionActive)
        controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction
        // BEGIN READER DIAGNOSTICS update screen facts
        controller.interactionDiagnostics.screenFacts(window: window != nil, loading: diagnosticLoading,
            saveFailed: diagnosticSaveFailed, tools: diagnosticTools)
        // END READER DIAGNOSTICS update screen facts
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
