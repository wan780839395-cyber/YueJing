import ReaderDomain
import SwiftUI
import UIKit

// A native scene acceptance, scoped to one route, VC and scene binding.
struct ReaderSceneEvent: Equatable {
    let routeID: UUID
    let owner: ObjectIdentifier
    let binding: UUID
    let revision: UUID
    let active: Bool
}

@MainActor
final class ReaderViewportHandle {
    weak var controller: ReaderViewController?
    private var restoration: ReaderViewportRestoration?
    private(set) var interactionActive = true
    private var nativeRouteID: UUID?
    private var sceneBinding: UUID?
    private var sceneRevision = UUID()
    private var acceptedSceneActive: Bool?
    private struct ModelSceneRequest {
        let event: ReaderSceneEvent
        let apply: @MainActor (Bool) async -> Void
    }
    private struct ModelSceneTransition {
        let id: UUID
        let request: ModelSceneRequest
        var started = false
    }
    // Initial .task(load) is active. A cancelled, started operation is NOT a completed phase.
    private var completedModelPhase: Bool? = true
    private var modelSceneRouteID: UUID?
    private var pendingModelScene: ModelSceneRequest?
    private var modelSceneTransition: ModelSceneTransition?
    private(set) var modelSceneTask: Task<Void, Never>?

    func configureSceneAuthority(_ value: ReaderViewController, routeID: UUID,
                                onChange: @escaping @MainActor (ReaderSceneEvent) -> Void) {
        guard controller === value else { return }
        if let modelSceneRouteID, modelSceneRouteID != routeID {
            modelSceneTask?.cancel(); pendingModelScene = nil; completedModelPhase = nil
        }
        modelSceneRouteID = routeID
        nativeRouteID = routeID
        value.prepareSceneAuthority(handle: self, routeID: routeID)
        value.onSceneInteraction = onChange
    }
    func ownsSceneController(_ value: ReaderViewController, routeID: UUID) -> Bool {
        controller === value && nativeRouteID == routeID
    }
    func beginSceneBinding(_ value: ReaderViewController, routeID: UUID, binding: UUID) -> Bool {
        guard ownsSceneController(value, routeID: routeID) else { return false }
        sceneBinding = binding; sceneRevision = UUID(); acceptedSceneActive = nil
        return true
    }
    func endSceneBinding(_ value: ReaderViewController, binding: UUID) {
        guard controller === value, sceneBinding == binding else { return }
        sceneBinding = nil; sceneRevision = UUID(); acceptedSceneActive = nil
        pendingModelScene = nil
    }
    @discardableResult
    func acceptScenePhase(_ active: Bool, from value: ReaderViewController, scene: UIWindowScene,
                          routeID: UUID, binding: UUID) -> Bool {
        guard ownsSceneController(value, routeID: routeID), sceneBinding == binding,
              value.matchesSceneBinding(binding, scene: scene),
              !active || scene.activationState == .foregroundActive,
              acceptedSceneActive != active else { return false }
        acceptedSceneActive = active; sceneRevision = UUID()
        applyInteractionActive(active)
        let event = ReaderSceneEvent(routeID: routeID, owner: ObjectIdentifier(value),
            binding: binding, revision: sceneRevision, active: active)
        value.onSceneInteraction?(event)
        return true
    }
    func isCurrent(_ event: ReaderSceneEvent, routeID: UUID) -> Bool {
        guard let controller else { return false }
        return event.routeID == routeID && nativeRouteID == routeID &&
            event.owner == ObjectIdentifier(controller) && event.binding == sceneBinding &&
            event.revision == sceneRevision && controller.matchesSceneBinding(event.binding)
    }
    func scheduleModelSceneTransition(_ event: ReaderSceneEvent, routeID: UUID,
                                     apply: @escaping @MainActor (Bool) async -> Void) {
        guard isCurrent(event, routeID: routeID) else { return }
        pendingModelScene = ModelSceneRequest(event: event, apply: apply)
        if let running = modelSceneTransition {
            // Same-route/phase rebinding adopts the in-flight work; it must not cancel load().
            if running.request.event.routeID != routeID || running.request.event.active != event.active {
                modelSceneTask?.cancel()
            }
            return // A cancelled operation must unwind before its successor can call load().
        }
        startModelSceneTransition()
    }
    private func startModelSceneTransition() {
        guard modelSceneTransition == nil, let request = pendingModelScene else { return }
        pendingModelScene = nil
        let event = request.event
        guard isCurrent(event, routeID: event.routeID), completedModelPhase != event.active else { return }
        let id = UUID()
        modelSceneTransition = ModelSceneTransition(id: id, request: request)
        modelSceneTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.isCurrent(event, routeID: event.routeID) else {
                self.finishModelSceneTransition(id, completed: false); return
            }
            self.modelSceneTransition?.started = true
            await request.apply(event.active)
            self.finishModelSceneTransition(id, completed: !Task.isCancelled)
        }
    }
    private func finishModelSceneTransition(_ id: UUID, completed: Bool) {
        guard let running = modelSceneTransition, running.id == id else { return }
        if running.started, running.request.event.routeID == modelSceneRouteID {
            completedModelPhase = completed ? running.request.event.active : nil
        }
        modelSceneTask = nil; modelSceneTransition = nil
        startModelSceneTransition() // Latest current owner takes over only after the old await settles.
    }
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
        // Compatibility input for unbound helper/Host users only. Production installs native authority.
        guard nativeRouteID == nil else { return }
        applyInteractionActive(active)
    }
    private func applyInteractionActive(_ active: Bool) {
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
        if controller !== value {
            nativeRouteID = nil; sceneBinding = nil; sceneRevision = UUID(); acceptedSceneActive = nil
            pendingModelScene = nil
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
        nativeRouteID = nil; sceneBinding = nil; sceneRevision = UUID(); acceptedSceneActive = nil
        pendingModelScene = nil
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
    let routeID: UUID
    let onSceneInteraction: @MainActor (ReaderSceneEvent) -> Void
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
        handle.attach(controller)
        controller.onAnchor = onAnchor; controller.onExtend = onExtend; controller.onWidth = onWidth
        controller.onSettled = onSettled
        controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction
        handle.configureSceneAuthority(controller, routeID: routeID, onChange: onSceneInteraction)
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
        handle.configureSceneAuthority(controller, routeID: routeID, onChange: onSceneInteraction)
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
