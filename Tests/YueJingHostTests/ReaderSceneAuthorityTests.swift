import Foundation
import ReaderDomain
import Testing
import UIKit
import XCTest
@testable import YueJing

// Real host window/scene + UIKit-completed root and explicitly paired child appearance transitions.
// Exercises production binding, selector observer, parent delivery and coordinator contract.
// Scene notifications/model work are injected; no automatic child delivery or actual App-switch proof.
@MainActor
@Suite(.serialized)
struct ReaderSceneAuthorityTests {
    @Test func nativeSceneAuthorityRejectsStaleOwnersAndDuplicatePhaseWrites() async throws {
        // All root waits consume the same case budget, never a fresh timeout per transition.
        let rootDeadline = ContinuousClock.now.advanced(by: .seconds(180))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let fixture = AppearanceContainer()
        defer {
            if !fixture.children.isEmpty { fixture.removeAllChildren() }
            // Failure-only fallback: no claim that an unawaited root callback completed.
            fixture.detachRootForFailureCleanup(in: host)
            if !host.isHidden { host.isHidden = true }
        }
        try await fixture.installRoot(in: host, before: rootDeadline)
        @MainActor func deliverAttachedAppearance(_ controller: ReaderViewController,
                                                 handle: ReaderViewportHandle, routeID: UUID) throws {
            try fixture.requireRootAppearance(true)
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
            try #require(host.rootViewController === fixture && !host.isHidden)
            try fixture.requireRootAppearance(true)
            fixture.removeAllChildren()
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
        try await fixture.removeRoot(from: host, before: rootDeadline)
        try fixture.requireRootAppearance(false)
        try #require(fixture.viewIfLoaded?.window == nil && replacement.viewIfLoaded?.window == nil)
        fixture.expectRootDetached()
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(events.count == reboundCount)
        handle.detach(replacement)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(events.count == reboundCount && handle.controller == nil && replacement.sceneBindingID == nil)

        fixture.removeAllChildren()
        try await fixture.installRoot(in: host, before: rootDeadline)

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
        try await fixture.removeRoot(from: host, before: rootDeadline)
        fixture.expectRootDetached()
        fixture.removeAllChildren()
    }

    // UIKit alone drives root appearance. Only real did callbacks release the bounded waits.
    // Automatic child forwarding stays off; child appearance has its own single paired driver.
    @MainActor
    private final class AppearanceContainer: UIViewController {
        override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
        private var appeared: Set<ObjectIdentifier> = []
        private var rootAppearance: Bool? = false
        private var rootWillAppear = 0, rootDidAppear = 0
        private var rootWillDisappear = 0, rootDidDisappear = 0
        private var didAppearCompletion: XCTestExpectation?
        private var didDisappearCompletion: XCTestExpectation?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            rootWillAppear += 1; rootAppearance = nil
            traceRoot("willAppear")
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            rootDidAppear += 1; rootAppearance = true
            traceRoot("didAppear")
            let completion = didAppearCompletion; didAppearCompletion = nil
            completion?.fulfill()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            rootWillDisappear += 1; rootAppearance = nil
            traceRoot("willDisappear")
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            rootDidDisappear += 1; rootAppearance = false
            traceRoot("didDisappear")
            let completion = didDisappearCompletion; didDisappearCompletion = nil
            completion?.fulfill()
        }
        func installRoot(in window: UIWindow, before deadline: ContinuousClock.Instant) async throws {
            try #require(window.rootViewController == nil && viewIfLoaded?.window == nil)
            try #require(children.isEmpty && appeared.isEmpty)
            try #require(didAppearCompletion == nil && didDisappearCompletion == nil)
            let completion = XCTestExpectation(description: "root didAppear")
            didAppearCompletion = completion
            defer { didAppearCompletion = nil }
            traceRoot("install.begin")
            window.rootViewController = self
            window.isHidden = false
            traceRoot("install.mutated")
            try await waitForRootCallback(completion, before: deadline)
            try requireRootAppearance(true)
            try #require(window.rootViewController === self && viewIfLoaded?.window === window)
            traceRoot("installed")
        }
        func removeRoot(from window: UIWindow, before deadline: ContinuousClock.Instant) async throws {
            try #require(window.rootViewController === self && viewIfLoaded?.window === window && !window.isHidden)
            try requireRootAppearance(true)
            try #require(didAppearCompletion == nil && didDisappearCompletion == nil)
            disappearAll()
            let completion = XCTestExpectation(description: "root didDisappear")
            didDisappearCompletion = completion
            defer { didDisappearCompletion = nil }
            traceRoot("remove.begin")
            window.rootViewController = nil
            traceRoot("remove.mutated")
            try await waitForRootCallback(completion, before: deadline)
            try requireRootAppearance(false)
            #expect(rootAppearance == false && rootWillAppear == rootDidAppear && rootWillDisappear == rootDidDisappear)
            try #require(viewIfLoaded?.window == nil)
            window.isHidden = true
            traceRoot("disappeared")
        }
        private func waitForRootCallback(_ completion: XCTestExpectation,
                                         before deadline: ContinuousClock.Instant) async throws {
            let remaining = ContinuousClock.now.duration(to: deadline)
            try #require(remaining > .zero)
            let parts = remaining.components
            let timeout = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            // Async XCTWaiter suspends rather than blocking MainActor; fulfillment is callback-only.
            let result = await XCTWaiter.fulfillment(of: [completion], timeout: timeout)
            try #require(result == .completed)
        }
        func detachRootForFailureCleanup(in window: UIWindow) {
            guard window.rootViewController === self else { return }
            traceRoot("cleanup.unverified.begin")
            window.rootViewController = nil
            traceRoot("cleanup.unverified.mutated")
        }
        func requireRootAppearance(_ active: Bool) throws {
            try #require(rootAppearance == active && rootWillAppear == rootDidAppear && rootWillDisappear == rootDidDisappear)
        }
        func expectRootDetached() {
            #expect(viewIfLoaded?.window == nil && rootAppearance == false
                && rootWillAppear == rootDidAppear && rootWillDisappear == rootDidDisappear)
            traceRoot("detached")
        }
        private func traceRoot(_ event: String) {
            print("HOST_ROOT_LIFECYCLE \(ObjectIdentifier(self)) \(event) appear=\(rootWillAppear)/\(rootDidAppear) disappear=\(rootWillDisappear)/\(rootDidDisappear)")
        }

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
