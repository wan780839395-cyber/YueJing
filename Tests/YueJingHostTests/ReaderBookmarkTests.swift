import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct ReaderBookmarkTests {
    @Test func bookmarkVisibleCaptureAndMutationsDoNotSaveProgress() async throws {
        try await withReader { model, controller, service, book in
            let visible = try #require(controller.bookmarkAnchor())
            #expect(visible.lineFraction == 0)
            let presentation = UUID()
            model.beginBookmarkPanel(presentation)
            #expect(model.bookmarks.canAdd)
            model.bookmarks.add()
            try await waitUntil { !model.bookmarks.isBusy }
            let saved = try #require(model.bookmarks.page?.items.first)
            #expect(saved.rawByteOffset == visible.rawByteOffset)
            #expect(model.bookmarks.page?.total == 1 && !model.bookmarks.canAdd)
            model.bookmarks.add() // Disabled duplicate intent cannot create another row.
            #expect(model.bookmarks.page?.total == 1)
            let originalWindow = try #require(model.window)
            let table = try #require(controller.view.subviews.first { $0 is UITableView } as? UITableView)
            let secondLine = try #require(originalWindow.slices.first?.lines.dropFirst().first)
            model.endBookmarkPanel(presentation)
            // One line, not a chapter or a large scroll threshold.
            table.setContentOffset(CGPoint(x: 0, y: CGFloat(secondLine.top) - table.adjustedContentInset.top + 1), animated: false)
            let nearby = try #require(controller.bookmarkAnchor())
            #expect(nearby.rawByteOffset == secondLine.rawByteStart)
            #expect(nearby.rawByteOffset != visible.rawByteOffset)
            let nearbyPanel = UUID()
            model.beginBookmarkPanel(nearbyPanel)
            model.bookmarks.show()
            try await waitUntil { !model.bookmarks.isBusy }
            #expect(model.bookmarks.canAdd)
            model.bookmarks.add()
            try await waitUntil { !model.bookmarks.isBusy }
            #expect(model.bookmarks.page?.total == 2)
            let second = try #require(model.bookmarks.page?.items.first { $0.id != saved.id })
            #expect(second.chapterTitleSnapshot == saved.chapterTitleSnapshot)
            #expect(second.rawByteOffset == nearby.rawByteOffset)
            model.bookmarks.rename(second, name: "  同章第二处 👩‍💻  ")
            try await waitUntil { !model.bookmarks.isBusy }
            let renamed = try #require(model.bookmarks.page?.items.first { $0.id == second.id })
            #expect(renamed.customName == "同章第二处 👩‍💻")
            #expect(renamed.rawByteOffset == second.rawByteOffset && renamed.createdAt == second.createdAt)
            model.bookmarks.rename(renamed, name: "\n ")
            try await waitUntil { !model.bookmarks.isBusy }
            #expect(model.bookmarks.page?.items.first { $0.id == second.id }?.customName == nil)
            model.bookmarks.delete(second)
            try await waitUntil { !model.bookmarks.isBusy }
            model.endBookmarkPanel(nearbyPanel)
            apply(originalWindow, to: model, controller: controller, navigation: false)
            model.beginBookmarkPanel(presentation)
            model.bookmarks.show()
            try await waitUntil { !model.bookmarks.isBusy }
            model.bookmarks.delete(saved)
            try await waitUntil { !model.bookmarks.isBusy }
            #expect(model.bookmarks.page?.total == 0 && model.bookmarks.canAdd)
            #expect(await model.close())
            let reopened = try await service.openReader(id: book.id, budget: ReaderStoragePolicy.budget())
            #expect(reopened.reading.anchor == nil)
            #expect(try await reopened.bookmarkPage(start: 0, request: BookmarkRequest()).total == 0)
            try await reopened.close()
        }
    }

    @Test func bookmarkQueuedCancellationAndOldDismissCannotAffectNewPanel() async throws {
        try await withReader { model, _, _, _ in
            let old = UUID(), current = UUID()
            model.beginBookmarkPanel(old)
            #expect(model.bookmarks.canAdd)
            model.bookmarks.add()
            model.endBookmarkPanel(old) // Synchronous revocation before the MainActor task runs.
            model.beginBookmarkPanel(current)
            model.endBookmarkPanel(old)
            #expect(model.bookmarks.presentationID == current)
            model.bookmarks.show()
            try await waitUntil { !model.bookmarks.isBusy }
            #expect(model.bookmarks.page?.total == 0)
            #expect(model.bookmarks.message == nil)
            #expect(model.bookmarks.canAdd)
            model.bookmarks.invalidatePosition()
            #expect(!model.bookmarks.canAdd && model.bookmarks.positionMessage != nil)
            model.bookmarks.add()
            #expect(!model.bookmarks.isBusy && model.bookmarks.page?.total == 0)
            model.refreshBookmarkCapture(current)
            #expect(model.bookmarks.canAdd)
            model.endBookmarkPanel(old)
            #expect(model.bookmarks.presentationID == current)
        }
    }

    @Test func bookmarkPreparationPreservesWindowUntilExactApplication() async throws {
        try await withReader { model, controller, service, book in
            let original = try #require(model.window)
            let table = try #require(controller.view.subviews.first { $0 is UITableView } as? UITableView)
            #expect(table.contentSize.height > table.bounds.height + 600)
            // Read-only capture of a distant visible line; no synthetic user-progress callback.
            table.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            table.layoutIfNeeded()
            let distant = try #require(controller.bookmarkAnchor())
            #expect(distant.rawByteOffset > original.anchor.rawByteOffset)
            let first = UUID()
            model.beginBookmarkPanel(first); model.bookmarks.add()
            try await waitUntil { !model.bookmarks.isBusy }
            let saved = try #require(model.bookmarks.page?.items.first)
            model.endBookmarkPanel(first)
            apply(original, to: model, controller: controller, navigation: false)
            let presentation = UUID()
            model.beginBookmarkPanel(presentation)
            // A real position revision after panel opening must not poison a fresh jump request.
            let changed = ReadingAnchor(bookID: original.anchor.bookID, versionID: original.anchor.versionID,
                rawByteOffset: original.anchor.rawByteOffset, lineFraction: 0.25)
            model.visibleChanged(changed, windowID: original.id)
            #expect(!model.bookmarks.canAdd)
            let beforeFailure = controller.restorableAnchor()
            await #expect(throws: LibraryError.invalidAnchor) {
                try await model.prepareBookmarkWindow(id: UUID().uuidString, presentation: presentation, request: BookmarkRequest())
            }
            #expect(model.window?.id == original.id && controller.restorableAnchor() == beforeFailure)
            model.refreshBookmarkCapture(presentation)
            #expect(model.bookmarks.canAdd)
            model.visibleChanged(changed, windowID: original.id) // Equivalent UIKit callback.
            #expect(model.bookmarks.canAdd)
            // Invalidate again so the following successful prepare proves separation from add capture.
            model.visibleChanged(original.anchor, windowID: original.id)
            #expect(!model.bookmarks.canAdd)
            let prepared = try await model.prepareBookmarkWindow(id: saved.id, presentation: presentation, request: BookmarkRequest())
            #expect(prepared.anchor.rawByteOffset == distant.rawByteOffset)
            #expect(model.window?.id == original.id && controller.window?.id == original.id)
            #expect(!model.applyBookmarkWindow(prepared, presentation: UUID()))
            #expect(model.window?.id == original.id)
            #expect(model.applyBookmarkWindow(prepared, presentation: presentation))
            #expect(controller.window?.id == original.id) // Model installation is not UIKit application.
            model.endBookmarkPanel(presentation)
            apply(prepared, to: model, controller: controller, navigation: true)
            let applied = try #require(controller.restorableAnchor())
            #expect(applied.rawByteOffset == distant.rawByteOffset)
            #expect(await model.close()) // Original final-save path persists only the applied target.
            let reopened = try await service.openReader(id: book.id, budget: ReaderStoragePolicy.budget())
            #expect(reopened.reading.anchor?.rawByteOffset == applied.rawByteOffset)
            try await reopened.close()
        }
        try await withReader { model, controller, service, book in
            let original = try #require(model.window)
            let table = try #require(controller.view.subviews.first { $0 is UITableView } as? UITableView)
            let line = try #require(original.slices.first?.lines.dropFirst().first)
            table.setContentOffset(CGPoint(x: 0, y: CGFloat(line.top) - table.adjustedContentInset.top + 1), animated: false)
            let nearby = try #require(controller.bookmarkAnchor())
            #expect(nearby.rawByteOffset == line.rawByteStart)
            let first = UUID()
            model.beginBookmarkPanel(first); model.bookmarks.add()
            try await waitUntil { !model.bookmarks.isBusy }
            let saved = try #require(model.bookmarks.page?.items.first)
            model.bookmarks.rename(saved, name: "附近跳转")
            try await waitUntil { !model.bookmarks.isBusy }
            model.endBookmarkPanel(first)
            apply(original, to: model, controller: controller, navigation: false)
            let jump = UUID()
            model.beginBookmarkPanel(jump)
            let prepared = try await model.prepareBookmarkWindow(id: saved.id, presentation: jump, request: BookmarkRequest())
            #expect(model.applyBookmarkWindow(prepared, presentation: jump))
            model.endBookmarkPanel(jump)
            apply(prepared, to: model, controller: controller, navigation: true)
            #expect(controller.bookmarkAnchor()?.rawByteOffset == nearby.rawByteOffset)
            #expect(await model.close())
            let reopened = try await service.openReader(id: book.id, budget: ReaderStoragePolicy.budget())
            #expect(reopened.reading.anchor?.rawByteOffset == nearby.rawByteOffset)
            #expect(try await reopened.bookmarkPage(start: 0, request: BookmarkRequest()).items.first?.customName == "附近跳转")
            try await reopened.close()
        }
    }

    @Test func bookmarkReflowAndOwnerReplacementRevokeCapturedAndPreparedPositions() async throws {
        try await withReader { model, controller, _, _ in
            let presentation = UUID()
            model.beginBookmarkPanel(presentation); model.bookmarks.add()
            try await waitUntil { !model.bookmarks.isBusy }
            let saved = try #require(model.bookmarks.page?.items.first)
            let prepared = try await model.prepareBookmarkWindow(id: saved.id, presentation: presentation, request: BookmarkRequest())
            model.resized(430)
            #expect(!model.bookmarks.canAdd && model.bookmarks.positionMessage != nil)
            #expect(!model.applyBookmarkWindow(prepared, presentation: presentation))
            try await waitUntil { model.window?.id != controller.window?.id }
            let reflowed = try #require(model.window)
            apply(reflowed, to: model, controller: controller, navigation: false)
            // Old prepared result stays rejected, but a NEW request after reflow is valid.
            #expect(!model.applyBookmarkWindow(prepared, presentation: presentation))
            let refreshed = try await model.prepareBookmarkWindow(id: saved.id, presentation: presentation, request: BookmarkRequest())
            #expect(refreshed.anchor.rawByteOffset == saved.rawByteOffset)
            #expect(model.window?.id == reflowed.id)
            model.endBookmarkPanel(presentation)
            let current = UUID()
            model.beginBookmarkPanel(current)
            let replacement = ReaderViewController()
            model.viewport.attach(replacement)
            #expect(!model.bookmarks.owns(current) && !model.bookmarks.canAdd)
            await #expect(throws: LibraryError.invalidAnchor) {
                try await model.prepareBookmarkWindow(id: saved.id, presentation: current, request: BookmarkRequest())
            }
            model.windowApplied(reflowed.id)
            #expect(model.bookmarks.presentationID == nil)
            model.viewport.attach(controller)
            model.beginBookmarkPanel(UUID())
            model.viewport.setInteractionActive(false)
            #expect(!model.bookmarks.canAdd)
            await model.suspend()
            #expect(model.bookmarks.presentationID == nil && !model.bookmarks.isBusy)
        }
    }

    private func apply(_ window: ReadingWindow, to model: ReaderViewModel,
                       controller: ReaderViewController, navigation: Bool) {
        // Same ordering as ReaderViewport.updateUIViewController, without appearance fabrication.
        model.viewport.onNextRestoreIsNavigation = false
        controller.apply(window, userNavigation: navigation)
        model.viewport.applied(controller)
        model.windowApplied(window.id)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The actual asynchronous operation did not finish within ten seconds")
    }

    private func withReader(_ check: @MainActor (ReaderViewModel, ReaderViewController, LibraryService, LibraryBook) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-Bookmark-Host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.txt")
        let text = "Chapter 1 BOOKMARK_HOST\n" + (1...300).map { "BOOKMARK_LINE_\($0) Synthetic visible anchor and persistence content.\n" }.joined()
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let imported = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = imported else {
            Issue.record("Synthetic UTF-8 BOM unexpectedly required selection"); return
        }
        let model = ReaderViewModel(bookID: receipt.book.id, service: service)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene), controller = ReaderViewController()
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.rootViewController = controller; host.isHidden = false
        defer { host.isHidden = true; host.rootViewController = nil }
        controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
        model.viewport.attach(controller)
        controller.onAnchor = { [weak model] in model?.visibleChanged($0, windowID: $1) }
        do {
            model.resized(390); await model.load()
            try await waitUntil { model.window != nil && !model.loading }
            let rendered = try #require(model.window)
            apply(rendered, to: model, controller: controller, navigation: false)
            try #require(controller.bookmarkAnchor() != nil)
            try await check(model, controller, service, receipt.book)
            _ = await model.close()
        } catch {
            _ = await model.close()
            throw error
        }
    }
}
