import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct TXTAutoReadingTests {
    @Test func playbackMovesTableAndBodyTouchOnlyPauses() async throws {
        try await withReader { model, controller, table, _, _ in
            let session = AutoReadSession()
            defer { session.stop() }
            controller.bindAutoReading(session)
            var anchors: [ReadingAnchor] = []
            controller.onAnchor = { value, windowID in
                anchors.append(value)
                model.visibleChanged(value, windowID: windowID)
            }
            let start = table.contentOffset.y
            controller.beginAutoReading()
            session.start(mode: .scroll) { model.advanceAutoReading(by: $0, in: controller) }
            try await waitUntil { table.contentOffset.y >= start + 2 }
            // Feed a burst of real one-pixel moves before the next display callback.
            let samples = anchors.count
            let pixel = 1 / max(1, table.traitCollection.displayScale)
            for _ in 0..<12 {
                try #require(model.advanceAutoReading(by: pixel, in: controller) == .advanced)
            }
            #expect(anchors.count - samples < 12)
            let expected = try #require(controller.visibleNavigationAnchor())
            let moved = table.contentOffset.y
            let point = CGPoint(x: 3, y: controller.view.bounds.midY)
            let bodyHit = try #require(controller.view.hitTest(point, with: nil))
            try #require(!bodyHit.isDescendant(of: table) && bodyHit !== controller.view)
            var toolEvents = 0
            controller.onToolsInteraction = { _ in toolEvents += 1 }
            // Exercise the actual hit target's touch-down handler, not a synthetic table pan.
            bodyHit.touchesBegan([], with: nil)
            #expect(!session.isRunning)
            #expect(anchors.last == expected)
            try await Task.sleep(for: .milliseconds(150))
            #expect(table.contentOffset.y == moved && toolEvents == 0)
            let manualHit = try #require(controller.view.hitTest(point, with: nil))
            #expect(manualHit === table || manualHit.isDescendant(of: table))
        }
    }

    @Test func boundaryWaitsForAppliedWindowThenStopsAtEOFAndSavesVisibleProgress() async throws {
        try await withReader { model, controller, table, service, book in
            var extensions = 0
            controller.onExtend = { anchor, id in
                extensions += 1
                model.extendWindow(anchor, windowID: id)
            }
            let initial = try #require(model.window)
            try #require(initial.hasNext)
            controller.beginAutoReading()
            for _ in 0..<20 {
                let window = try #require(model.window)
                let before = extensions
                // One large (clamped) move lets the test reach each real edge without wall-clock scrolling.
                try #require(model.advanceAutoReading(by: 100_000, in: controller) == .advanced)
                let bottom = table.contentOffset.y
                try #require(abs(bottom - (table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)) < 1)
                if !window.hasNext {
                    #expect(model.advanceAutoReading(by: 1, in: controller) == .stop)
                    #expect(extensions == before && extensions > 0 && table.contentOffset.y == bottom)
                    let expected = try #require(controller.visibleNavigationAnchor())
                    #expect(expected.rawByteOffset > initial.anchor.rawByteOffset)
                    try #require(await model.close())
                    let reopened = try await service.openReader(id: book.id, budget: ReaderStoragePolicy.budget())
                    #expect(reopened.reading.anchor == expected)
                    try await reopened.close()
                    return
                }
                try #require(model.advanceAutoReading(by: 1, in: controller) == .waiting)
                #expect(model.advanceAutoReading(by: 1, in: controller) == .waiting)
                try await waitUntil { model.window?.id != window.id }
                #expect(model.advanceAutoReading(by: 1, in: controller) == .waiting) // Not yet applied.
                #expect(extensions == before + 1 && table.contentOffset.y == bottom)
                let next = try #require(model.window)
                #expect(next.anchor == controller.restorableAnchor())
                apply(next, model, controller)
            }
            Issue.record("Forward extension did not reach the end of the synthetic book")
        }
    }

    @Test func speechPullsFromVisibleLineWhileSuspendedAndRestoresFinalFragment() async throws {
        try await withReader { model, controller, table, service, book in
            let initial = try #require(model.window)
            table.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
            let visible = try #require(controller.visibleNavigationAnchor())
            try #require(visible.rawByteOffset > initial.anchor.rawByteOffset)
            let lease = try #require(model.makeSpeechCursor())
            await model.suspend(); model.viewport.detach(controller)
            let first = try #require(try await lease.cursor.next())
            #expect(first.anchor.rawByteOffset == visible.rawByteOffset)
            var heard = first.anchor
            while let fragment = try await lease.cursor.next() { heard = fragment.anchor }
            model.restoreSpeech(heard, lease: lease.id)
            try #require(model.speechNavigation != nil && model.window?.id == initial.id)
            model.viewport.attach(controller); await model.resume()
            try await waitUntil { model.window?.id != initial.id }
            let restored = try #require(model.window)
            #expect(restored.anchor == heard)
            controller.apply(restored, userNavigation: model.viewport.onNextRestoreIsNavigation)
            model.viewport.applied(controller); model.windowApplied(restored.id)
            #expect(controller.navigationTargetVisible && model.speechNavigation == nil)
            try #require(await model.close())
            let reopened = try await service.openReader(id: book.id, budget: ReaderStoragePolicy.budget())
            #expect(reopened.reading.anchor == heard)
            try await reopened.close()
        }
    }

    @Test func manualNavigationRevokesPendingSpeechLayoutAndLateLocate() async throws {
        try await withReader { model, controller, _, _, _ in
            let displayed = try #require(controller.window)
            let old = try #require(model.makeSpeechCursor())
            let current = try #require(model.makeSpeechCursor())
            let fragment = try #require(try await current.cursor.next())
            model.restoreSpeech(fragment.anchor, lease: old.id)
            #expect(model.speechNavigation == nil)
            model.restoreSpeech(fragment.anchor, lease: current.id)
            try await waitUntil { model.window?.id != displayed.id } // Layout published, not yet applied.
            model.beginManualNavigation()
            model.restoreSpeech(fragment.anchor, lease: current.id)
            #expect(model.window?.id == displayed.id && model.speechNavigation == nil)
            #expect(model.speechAvailable)
        }
    }

    private func apply(_ window: ReadingWindow, _ model: ReaderViewModel, _ controller: ReaderViewController) {
        controller.apply(window, userNavigation: false)
        model.viewport.applied(controller)
        model.windowApplied(window.id)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func withReader(_ check: @MainActor (ReaderViewModel, ReaderViewController, UITableView, LibraryService, LibraryBook) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TXT-AutoRead-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.txt")
        let text = "Chapter 1\n" + (1...200).map { "Line \($0) of the synthetic auto-reading fixture.\n" }.joined()
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let imported = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = imported else { Issue.record("UTF-8 fixture did not import"); return }
        let model = ReaderViewModel(bookID: receipt.book.id, service: service)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene), controller = ReaderViewController()
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.rootViewController = controller; host.isHidden = false
        defer { host.isHidden = true; host.rootViewController = nil }
        controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
        model.viewport.attach(controller)
        controller.onAnchor = model.visibleChanged
        do {
            model.resized(390); await model.load()
            try await waitUntil { model.window != nil && !model.loading }
            let initial = try #require(model.window)
            apply(initial, model, controller)
            let table = try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
            try await check(model, controller, table, service, receipt.book)
            if model.window != nil { _ = await model.close() }
        } catch {
            _ = await model.close()
            throw error
        }
    }
}
