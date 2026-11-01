import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

// Actual host window/scene + production selector observer and parent delivery path.
// Notifications below are injected; this is NOT a physical App-switch or native touch test.
@MainActor
@Suite(.serialized)
struct ReaderSceneAuthorityTests {
    @Test func nativeSceneAuthorityRejectsStaleOwnersAndDuplicatePhaseWrites() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
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
        handle.attach(old)
        handle.configureSceneAuthority(old, routeID: route, onChange: parent)
        defer { if let current = handle.controller { handle.detach(current) }; host.isHidden = true; host.rootViewController = nil }
        #expect(events.isEmpty) // make/configure cannot mutate parent state before window attachment.
        host.rootViewController = old; host.isHidden = false
        old.beginAppearanceTransition(true, animated: false); old.endAppearanceTransition()
        #expect(old.view.window?.windowScene === scene)
        let oldBinding = try #require(old.sceneBindingID), initial = try #require(events.last)
        #expect(initial.active && initial.routeID == route && initial.owner == ObjectIdentifier(old))
        #expect(events.count == 1 && modelTransitions.isEmpty) // Initial .task(load), no duplicate resume.
        let intent = tools.intent, generation = old.interactionContext.generation
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        old.viewDidAppear(false) // A sheet return must not allocate another binding or intent.
        #expect(events.count == 1 && tools.intent == intent && old.interactionContext.generation == generation)
        #expect(old.sceneBindingID == oldBinding)
        old.viewDidDisappear(false)
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
        handle.attach(replacement)
        handle.configureSceneAuthority(replacement, routeID: route, onChange: parent)
        host.rootViewController = replacement
        replacement.beginAppearanceTransition(true, animated: false); replacement.endAppearanceTransition()
        let replacementBinding = try #require(replacement.sceneBindingID)
        #expect(old.sceneBindingID == nil && old.onSceneInteraction == nil && !old.interactionContext.active)
        let count = events.count
        handle.detach(old); old.viewDidAppear(false)
        #expect(!handle.acceptScenePhase(true, from: old, scene: scene, routeID: route, binding: oldBinding))
        #expect(!handle.acceptScenePhase(false, from: old, scene: scene, routeID: route, binding: oldBinding))
        #expect(events.count == count && handle.controller === replacement && handle.interactionActive)
        #expect(!handle.isCurrent(resumed, routeID: route))

        // Same real scene, new route/binding: queued old events must not address the replacement binding.
        let nextRoute = UUID()
        handle.configureSceneAuthority(replacement, routeID: nextRoute, onChange: parent)
        #expect(replacement.sceneBindingID == nil)
        replacement.viewDidAppear(false)
        await handle.modelSceneTask?.value
        let newBinding = try #require(replacement.sceneBindingID)
        #expect(newBinding != replacementBinding)
        let reboundCount = events.count
        #expect(!handle.acceptScenePhase(false, from: replacement, scene: scene, routeID: route, binding: replacementBinding))
        #expect(!handle.acceptScenePhase(false, from: replacement, scene: scene, routeID: nextRoute, binding: replacementBinding))
        #expect(events.count == reboundCount && modelTransitions == [false, true, true] && tools.intent == resumedIntent)
        host.rootViewController = nil // The actual current window must still belong to the bound scene.
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
        @MainActor func mount(_ controller: ReaderViewController) {
            asyncHandle.attach(controller)
            asyncHandle.configureSceneAuthority(controller, routeID: asyncRoute, onChange: asyncParent)
            host.rootViewController = controller
            controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
        }
        defer { open.release(); if let current = asyncHandle.controller { asyncHandle.detach(current) } }
        mount(first)
        #expect(applied.isEmpty && asyncHandle.modelSceneTask == nil)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        await asyncHandle.modelSceneTask?.value
        open.blockNextActive = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await open.requireWaiting()
        let recovering = try #require(asyncHandle.modelSceneTask)
        let second = ReaderViewController()
        mount(second) // Same route + active, while resume -> open is still suspended.
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
        mount(third) // No await between active delivery and replacement.
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
