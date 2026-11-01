import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

// Real VC + production input-helper event injection, NOT native UITouch reproduction.
@MainActor
@Suite(.serialized)
struct ReaderInteractionInterruptionTests {
    @Test func interruptedDecelerationRecoversOnSameControllerWithoutMovingAnchor() async throws {
        try await withController { controller, handle, table, rendered in
            var tools = ReadingToolsPresentation()
            controller.toolIntent = { tools.intent }
            controller.onToolsInteraction = { event in
                if case .tap(let intent, .toggle) = event { tools.bodyTapped(expected: intent) }
            }
            let anchor = try #require(handle.anchor()), offset = table.contentOffset
            let windowID = controller.window?.id
            #expect(!table.isDragging && !table.isDecelerating)
            // Inject the candidate omission: didEndDragging(true), NO didEndDecelerating.
            table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: true)
            #expect(controller.interactionContext.toolDecelerating)
            handle.setInteractionActive(false); tools.suspend()
            handle.setInteractionActive(false); tools.suspend()
            #expect(!controller.interactionContext.toolDecelerating)
            handle.setInteractionActive(true); tools.resume()
            #expect(!tools.visible && tools.canInteract)
            let fresh = try #require(controller.beginToolTouch())
            controller.latchToolTouch(fresh)
            #expect(controller.endToolTouch(fresh) == .toggle)
            #expect(tools.visible)
            #expect(controller.endToolTouch(controller.beginToolTouch()) == .toggle)
            #expect(!tools.visible)
            #expect(handle.controller === controller && controller.window?.id == windowID)
            #expect(windowID == rendered.id && handle.anchor() == anchor && table.contentOffset == offset)
        }
    }

    @Test func interruptionRevokesOldTouchAndAcceptsFreshIntent() async throws {
        try await withController { controller, handle, _, _ in
            var tools = ReadingToolsPresentation(), delivered: [UUID] = []
            controller.toolIntent = { tools.intent }
            controller.onToolsInteraction = { event in
                if case .tap(let intent, .toggle) = event {
                    delivered.append(intent); tools.bodyTapped(expected: intent)
                }
            }
            let oldIntent = tools.intent, old = try #require(controller.beginToolTouch())
            handle.setInteractionActive(false); tools.suspend()
            #expect(controller.endToolTouch(old) == nil && controller.beginToolTouch() == nil)
            handle.setInteractionActive(true); tools.resume()
            let freshIntent = tools.intent, fresh = try #require(controller.beginToolTouch())
            #expect(freshIntent != oldIntent)
            #expect(controller.endToolTouch(old) == nil) // Must not consume the fresh touch.
            controller.cancelToolTouch(old)
            #expect(controller.endToolTouch(fresh) == .toggle)
            #expect(delivered == [freshIntent] && tools.visible)
            let cancelled = try #require(controller.beginToolTouch())
            controller.cancelToolTouch(cancelled)
            #expect(controller.endToolTouch(cancelled) == nil)
            #expect(controller.endToolTouch(controller.beginToolTouch()) == .toggle)
            #expect(delivered.count == 2 && !tools.visible)
        }
    }

    @Test func momentumAtTouchBeginStillStopsBeforeANewIdleTouchCanToggle() async throws {
        try await withController { controller, _, table, _ in
            let intent = UUID()
            var decisions: [ReadingToolsTapDecision] = []
            controller.toolIntent = { intent }
            controller.onToolsInteraction = { event in
                if case .tap(let received, let decision) = event {
                    #expect(received == intent); decisions.append(decision)
                }
            }
            table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: true)
            let momentum = try #require(controller.beginToolTouch())
            controller.latchToolTouch(momentum)
            #expect(controller.interactionContext.touch?.beganDuringDeceleration == true)
            // UIKit is idle at end; removing the begin latch would incorrectly toggle here.
            table.delegate?.scrollViewDidEndDecelerating?(table)
            #expect(!table.isDecelerating)
            #expect(controller.endToolTouch(momentum) == .stopMomentum)
            #expect(controller.endToolTouch(controller.beginToolTouch()) == .toggle)
            // A stop consumes stale shadow too, without altering real UIKit inertia/offset.
            table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: true)
            #expect(controller.endToolTouch(controller.beginToolTouch()) == .stopMomentum)
            #expect(controller.endToolTouch(controller.beginToolTouch()) == .toggle)
            #expect(decisions == [.stopMomentum, .toggle, .stopMomentum, .toggle])
        }
    }

    @Test func viewportInterruptionForwardingIsIdempotentAndDetachedControllerIsInert() async throws {
        try await withController { old, handle, table, rendered in
            let intent = UUID()
            var lateEvents = 0
            old.toolIntent = { intent }; old.onToolsInteraction = { _ in lateEvents += 1 }
            let oldTouch = try #require(old.beginToolTouch())
            let anchor = handle.anchor()
            handle.setInteractionActive(false)
            let inactiveGeneration = old.interactionContext.generation
            handle.setInteractionActive(false)
            #expect(old.interactionContext.generation == inactiveGeneration)
            handle.setInteractionActive(true)
            let fresh = try #require(old.beginToolTouch()), activeGeneration = old.interactionContext.generation
            handle.setInteractionActive(true); handle.attach(old)
            #expect(old.interactionContext.generation == activeGeneration)
            #expect(old.endToolTouch(oldTouch) == nil && old.endToolTouch(fresh) == .toggle)
            #expect(lateEvents == 1)
            handle.setInteractionActive(false)
            let replacement = ReaderViewController()
            handle.attach(replacement)
            #expect(!replacement.interactionContext.active)
            replacement.toolIntent = { intent }
            replacement.onToolsInteraction = { _ in lateEvents += 10 }
            handle.detach(old) // Late dismantle cannot detach or reactivate the new owner.
            #expect(handle.controller === replacement && handle.anchor() == anchor)
            #expect(old.toolIntent == nil && old.onToolsInteraction == nil && !old.interactionContext.active)
            old.scrollViewWillBeginDragging(table)
            old.scrollViewDidEndDragging(table, willDecelerate: true)
            #expect(old.beginToolTouch() == nil && old.endToolTouch(oldTouch) == nil && lateEvents == 1)
            replacement.apply(rendered, userNavigation: false, restoring: handle.restoration(for: rendered.id))
            handle.applied(replacement)
            handle.setInteractionActive(true)
            #expect(replacement.endToolTouch(replacement.beginToolTouch()) == .toggle && lateEvents == 11)
            handle.detach(replacement)
            #expect(handle.controller == nil && !replacement.interactionContext.active)
            // An inactive phase received with no VC must be inherited by a later attach.
            let empty = ReaderViewportHandle(), later = ReaderViewController()
            empty.setInteractionActive(false); empty.setInteractionActive(false); empty.attach(later)
            later.toolIntent = { intent }
            #expect(!later.interactionContext.active && later.beginToolTouch() == nil)
            empty.setInteractionActive(true)
            #expect(later.endToolTouch(later.beginToolTouch()) == .toggle)
        }
    }

    private func withController(_ check: @MainActor (ReaderViewController, ReaderViewportHandle, UITableView, ReadingWindow) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-Interruption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // Disposable synthetic fixture only.
        let source = root.appendingPathComponent("Synthetic.txt")
        let text = "Chapter 1 UI_INTERRUPTION\n" + (1...300).map { "UI_INTERRUPTION_LINE_\($0) Synthetic interruption recovery content.\n" }.joined()
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let prepared = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = prepared else { Issue.record("Synthetic UTF-8 BOM unexpectedly required selection"); return }
        let reader = try await service.openReader(id: receipt.book.id, budget: ReaderStoragePolicy.budget())
        do {
            let anchor = ReadingAnchor(bookID: receipt.book.id, versionID: receipt.book.versionID,
                rawByteOffset: reader.source.metadata.bomByteCount)
            let rendered = try await reader.window(around: anchor, width: 350, preferences: reader.preferences)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIWindow(windowScene: scene)
            host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            defer { host.isHidden = true; host.rootViewController = nil }
            let controller = ReaderViewController(), handle = ReaderViewportHandle()
            host.rootViewController = controller; host.isHidden = false
            controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
            handle.attach(controller); controller.apply(rendered, userNavigation: false)
            let table = try #require(controller.view.subviews.first { $0 is UITableView } as? UITableView)
            try check(controller, handle, table, rendered)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }
}
