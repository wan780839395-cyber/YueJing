import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

// Real host window/scene + container-owned, paired child appearance transitions: production
// binding, selector observer, parent delivery and coordinator contract, NOT automatic child delivery.
// Scene notifications and suspended model work are injected; no actual App-switch or touch proof.
@MainActor
@Suite(.serialized)
struct ReaderSceneAuthorityTests {
    @Test func nativeSceneAuthorityRejectsStaleOwnersAndDuplicatePhaseWrites() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let fixture = AppearanceContainer()
        defer {
            fixture.removeAllChildren()
            host.isHidden = true
            host.rootViewController = nil
        }
        @MainActor func deliverAttachedAppearance(_ controller: ReaderViewController,
                                                 handle: ReaderViewportHandle, routeID: UUID) throws {
            fixture.disappear(controller) // A return/rebind first closes the previous appearance.
            host.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            try #require(host.rootViewController === fixture && controller.parent === fixture && !host.isHidden)
            try #require(host.windowScene === scene)
            try #require(controller.viewIfLoaded?.window === host)
            try #require(controller.viewIfLoaded?.window?.windowScene === scene)
            try #require(handle.controller === controller)
            try #require(handle.ownsSceneController(controller, routeID: routeID))
            try #require(controller.onSceneInteraction != nil)
            try #require(scene.activationState == .foregroundActive)
            try fixture.appear(controller) // Production creates the binding and observer.
        }
        @MainActor func mountConfigured(_ controller: ReaderViewController,
                                       handle: ReaderViewportHandle, routeID: UUID) throws {
            fixture.removeAllChildren()
            // UIKit owns the root lifecycle; only the fixture forwards to its children.
            // Restore the real window after the explicit root=nil rejection check below.
            if host.rootViewController == nil { host.rootViewController = fixture }
            host.isHidden = false
            try fixture.contain(controller)
            try deliverAttachedAppearance(controller, handle: handle, routeID: routeID)
        }
        let handle = ReaderViewportHandle(), old = ReaderViewController(), route = UUID()
        var tools = ReadingToolsPresentation(), events: [ReaderSceneEvent] = []
        var modelTransitions: [Bool] = []
        let parent: @MainActor (ReaderSceneEvent) -> Void = { event in
            #expect(handle.isCurrent(event, routeID: event.routeID))
            events.append(event)
            if event.active { tools.resume() } else { tools.suspend() }
            handle.scheduleModelSceneTransition(event, routeID: event.routeID) { active in
                modelTransitions.append(active)
            }
        }
        old.loadViewIfNeeded()
        handle.attach(old)
        handle.configureSceneAuthority(old, routeID: route, onChange: parent)
        defer { if let current = handle.controller { handle.detach(current) } }
        #expect(events.isEmpty) // make/configure cannot mutate parent state before window attachment.
        try mountConfigured(old, handle: handle, routeID: route)
        #expect(old.view.window?.windowScene === scene)
        let oldBinding = try #require(old.sceneBindingID), initial = try #require(events.last)
        #expect(initial.active && initial.routeID == route && initial.owner == ObjectIdentifier(old))
        #expect(events.count == 1 && modelTransitions.isEmpty) // Initial .task(load), no duplicate resume.
        let intent = tools.intent, generation = old.interactionContext.generation
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try deliverAttachedAppearance(old, handle: handle, routeID: route) // Sheet return: same binding/intent.
        #expect(events.count == 1 && tools.intent == intent && old.interactionContext.generation == generation)
        #expect(old.sceneBindingID == oldBinding)
        fixture.disappear(old)
        #expect(handle.interactionActive && tools.canInteract)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
        #expect(events.count == 1) // Wrong object; do not invent a second UIWindowScene.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(scene.activationState == .foregroundActive) // Injected willDeactivate must still pause immediately.
        #expect(!handle.interactionActive && !old.interactionContext.active && tools.suspended && !tools.visible)
        let pausedIntent = tools.intent, pausedGeneration = old.interactionContext.generation
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        #expect(events.count == 2 && tools.intent == pausedIntent && old.interactionContext.generation == pausedGeneration)
        #expect(!handle.isCurrent(initial, routeID: route))
        await handle.modelSceneTask?.value
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        await handle.modelSceneTask?.value
        #expect(events.count == 3 && handle.interactionActive && old.interactionContext.active)
        #expect(tools.canInteract && !tools.visible && modelTransitions == [false, true])
        let resumed = try #require(events.last), resumedIntent = tools.intent
        // Old SwiftUI environment values and legacy helper writes cannot overrule native authority.
        handle.observeDiagnosticScene(.background); handle.setInteractionActive(false)
        #expect(handle.interactionActive && old.interactionContext.active && tools.intent == resumedIntent)
        handle.scheduleModelSceneTransition(resumed, routeID: route) { _ in Issue.record("Duplicate completed phase ran model work") }
        #expect(events.count == 3 && handle.modelSceneTask == nil)
        #expect(!handle.isCurrent(resumed, routeID: UUID()))

        let replacement = ReaderViewController()
        replacement.loadViewIfNeeded()
        handle.attach(replacement)
        handle.configureSceneAuthority(replacement, routeID: route, onChange: parent)
        try mountConfigured(replacement, handle: handle, routeID: route)
        let replacementBinding = try #require(replacement.sceneBindingID)
        #expect(old.sceneBindingID == nil && old.onSceneInteraction == nil && !old.interactionContext.active)
        let count = events.count
        handle.detach(old)
        // Deliver the late lifecycle to an unauthorized child without reattaching the handle
        // or replacing the window root/current owner's view. No configured-owner helper here.
        try fixture.contain(old)
        try #require(host.rootViewController === fixture && replacement.view.window === host)
        try #require(old.viewIfLoaded?.window === host && old.viewIfLoaded?.window?.windowScene === scene)
        try #require(handle.controller === replacement && handle.ownsSceneController(replacement, routeID: route))
        try #require(old.onSceneInteraction == nil)
        try fixture.appear(old)
        fixture.remove(old)
        #expect(!handle.acceptScenePhase(true, from: old, scene: scene, routeID: route, binding: oldBinding))
        #expect(!handle.acceptScenePhase(false, from: old, scene: scene, routeID: route, binding: oldBinding))
        #expect(events.count == count && handle.controller === replacement && handle.interactionActive)
        #expect(!handle.isCurrent(resumed, routeID: route))

        // Same real scene, new route/binding: queued old events must not address the replacement binding.
        let nextRoute = UUID()
        handle.configureSceneAuthority(replacement, routeID: nextRoute, onChange: parent)
        #expect(replacement.sceneBindingID == nil)
        try deliverAttachedAppearance(replacement, handle: handle, routeID: nextRoute)
        await handle.modelSceneTask?.value
        let newBinding = try #require(replacement.sceneBindingID)
        #expect(newBinding != replacementBinding)
        let reboundCount = events.count
        #expect(!handle.acceptScenePhase(false, from: replacement, scene: scene, routeID: route, binding: replacementBinding))
        #expect(!handle.acceptScenePhase(false, from: replacement, scene: scene, routeID: nextRoute, binding: replacementBinding))
        #expect(events.count == reboundCount && modelTransitions == [false, true, true] && tools.intent == resumedIntent)
        fixture.disappearAll() // Close child appearances before UIKit detaches the root.
        host.rootViewController = nil // The actual current window must still belong to the bound scene.
        try #require(fixture.viewIfLoaded?.window == nil && replacement.viewIfLoaded?.window == nil)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(events.count == reboundCount)
        handle.detach(replacement)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(events.count == reboundCount && handle.controller == nil && replacement.sceneBindingID == nil)

        // P2: exercise the production single-task coordinator via the real observer/parent path.
        // Only the async model operation is injected; no test copy of the scheduling algorithm.
        let asyncHandle = ReaderViewportHandle(), first = ReaderViewController(), asyncRoute = UUID()
        let open = SuspendedOpen()
        var applied: [Bool] = [], appliedOwners: [ObjectIdentifier] = []
        let asyncParent: @MainActor (ReaderSceneEvent) -> Void = { event in
            asyncHandle.scheduleModelSceneTransition(event, routeID: asyncRoute) { active in
                applied.append(active); appliedOwners.append(event.owner)
                await open.apply(active)
            }
        }
        @MainActor func mount(_ controller: ReaderViewController) throws {
            controller.loadViewIfNeeded()
            asyncHandle.attach(controller)
            asyncHandle.configureSceneAuthority(controller, routeID: asyncRoute, onChange: asyncParent)
            try mountConfigured(controller, handle: asyncHandle, routeID: asyncRoute)
        }
        defer { open.release(); if let current = asyncHandle.controller { asyncHandle.detach(current) } }
        try mount(first)
        #expect(applied.isEmpty && asyncHandle.modelSceneTask == nil)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        await asyncHandle.modelSceneTask?.value
        open.blockNextActive = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await open.requireWaiting()
        let recovering = try #require(asyncHandle.modelSceneTask)
        let second = ReaderViewController()
        try mount(second) // Same route + active, while resume -> open is still suspended.
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(!recovering.isCancelled && open.started == 1 && open.completed == 0)
        open.release(); await recovering.value; await asyncHandle.modelSceneTask?.value
        #expect(open.started == 1 && open.completed == 1 && open.cancelled == 0)
        #expect(applied == [false, true] && asyncHandle.modelSceneTask == nil)

        // An old-owner active task that has NOT started must be rejected, then handed to the new owner.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        await asyncHandle.modelSceneTask?.value
        let countBeforeTakeover = applied.count
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        let notStarted = try #require(asyncHandle.modelSceneTask)
        let third = ReaderViewController()
        try mount(third) // No await between active delivery and replacement.
        await notStarted.value; await asyncHandle.modelSceneTask?.value
        #expect(applied.count == countBeforeTakeover + 1 && applied.last == true)
        #expect(appliedOwners.last == ObjectIdentifier(third) && asyncHandle.modelSceneTask == nil)

        // Active open is cancelled by inactive, then active returns BEFORE cancellation settles.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        await asyncHandle.modelSceneTask?.value
        open.blockNextActive = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await open.requireWaiting()
        let interrupted = try #require(asyncHandle.modelSceneTask), beforeInterruption = applied.count
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(interrupted.isCancelled && applied.count == beforeInterruption)
        open.release(); await interrupted.value; await asyncHandle.modelSceneTask?.value
        #expect(open.started == 2 && open.completed == 1 && open.cancelled == 1)
        #expect(applied.count == beforeInterruption + 1 && applied.last == true)
        #expect(asyncHandle.modelSceneTask == nil) // Cancelled active Bool cannot suppress its successor.
        let completedCount = applied.count
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(applied.count == completedCount && asyncHandle.modelSceneTask == nil)
    }

    // UIKit may transition the real window/root. Child appearance has exactly one driver:
    // this container, never automatic forwarding and never direct lifecycle callbacks.
    @MainActor
    private final class AppearanceContainer: UIViewController {
        override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
        private var appeared: Set<ObjectIdentifier> = []

        func contain(_ controller: UIViewController) throws {
            try #require(controller.parent == nil && !appeared.contains(ObjectIdentifier(controller)))
            loadViewIfNeeded()
            addChild(controller) // UIKit sends willMove(toParent:).
            controller.view.isHidden = true
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
        }
        func appear(_ controller: UIViewController) throws {
            try #require(controller.parent === self && controller.viewIfLoaded?.window != nil)
            try #require(!appeared.contains(ObjectIdentifier(controller)))
            controller.beginAppearanceTransition(true, animated: false)
            controller.view.isHidden = false
            controller.endAppearanceTransition()
            appeared.insert(ObjectIdentifier(controller))
        }
        func disappear(_ controller: UIViewController) {
            guard appeared.remove(ObjectIdentifier(controller)) != nil else { return }
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.isHidden = true
            controller.endAppearanceTransition()
        }
        func disappearAll() {
            for controller in children { disappear(controller) }
        }
        func remove(_ controller: UIViewController) {
            disappear(controller)
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent() // UIKit sends didMove(toParent: nil).
        }
        func removeAllChildren() {
            for controller in children { remove(controller) }
            #expect(appeared.isEmpty && children.isEmpty)
        }
    }

    @MainActor
    private final class SuspendedOpen {
        var blockNextActive = false
        private(set) var started = 0, completed = 0, cancelled = 0
        private var continuation: CheckedContinuation<Void, Never>?
        func apply(_ active: Bool) async {
            guard active, blockNextActive else { return }
            blockNextActive = false
            // Same cancellation propagation boundary as ReaderViewModel.load(): parent -> open task.
            // This is a suspended Swift operation, not a real LibraryService open or an App switch.
            let task = Task { [self] in
                started += 1
                await withCheckedContinuation { continuation = $0 }
                if Task.isCancelled { cancelled += 1 } else { completed += 1 }
            }
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        func requireWaiting() async throws {
            // Finite scheduler turns, no new wall-clock budget, Timer or retry in production.
            for _ in 0..<100 {
                if continuation != nil { return }
                await Task.yield()
            }
            try #require(continuation != nil)
        }
        func release() { let value = continuation; continuation = nil; value?.resume() }
    }
}
