import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct ReaderViewportLifecycleTests {
    @Test func rebuildKeepsDetachedAnchorUntilApplyAndRestoresTheScrolledWindow() async throws {
        try await verifyRebuild(attachNewFirst: false)
    }

    @Test func attachBeforeLateOldDismantlePreservesRestorationAndRejectsOldCallbacks() async throws {
        try await verifyRebuild(attachNewFirst: true)
    }

    private func verifyRebuild(attachNewFirst: Bool) async throws {
        try await withSyntheticWindow { rendered in
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIWindow(windowScene: scene)
            host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            defer { host.isHidden = true; host.rootViewController = nil }
            let old = ReaderViewController(), handle = ReaderViewportHandle()
            host.rootViewController = old; host.isHidden = false
            old.view.frame = host.bounds; old.view.layoutIfNeeded()
            handle.attach(old); old.apply(rendered, userNavigation: false)
            let table = try #require(old.view.subviews.first { $0 is UITableView } as? UITableView)
            #expect(table.contentSize.height > table.bounds.height + 800)
            old.scrollViewWillBeginDragging(table)
            table.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
            table.layoutIfNeeded(); old.scrollViewDidScroll(table)
            let expected = try #require(old.restorableAnchor())
            #expect(expected.rawByteOffset > rendered.anchor.rawByteOffset)
            let coordinator = ReaderViewport.Coordinator(handle: handle)
            var lateEvents = 0
            old.onWidth = { _ in lateEvents += 1 }
            old.onToolsInteraction = { _ in lateEvents += 1 }
            old.onAnchor = { _, _ in lateEvents += 1 }
            let replacement = ReaderViewController()
            if !attachNewFirst {
                ReaderViewport.dismantleUIViewController(old, coordinator: coordinator)
                #expect(handle.anchor() == expected)
            }
            handle.attach(replacement)
            #expect(handle.anchor() == expected) // A flush before apply still sees the reliable old anchor.
            ReaderViewport.dismantleUIViewController(old, coordinator: coordinator)
            #expect(handle.controller === replacement)
            #expect(old.onAnchor == nil && old.onExtend == nil && old.onWidth == nil && old.onSettled == nil)
            #expect(old.toolIntent == nil && old.onToolsInteraction == nil)
            old.view.frame.size.width += 1; old.viewDidLayoutSubviews()
            #expect(lateEvents == 0)
            host.rootViewController = replacement
            replacement.view.frame = host.bounds; replacement.view.layoutIfNeeded()
            replacement.apply(rendered, userNavigation: false, restoring: handle.restoration(for: rendered.id))
            handle.applied(replacement)
            let actual = try #require(handle.anchor())
            #expect(actual.bookID == expected.bookID && actual.versionID == expected.versionID)
            #expect(actual.rawByteOffset == expected.rawByteOffset)
            #expect(abs(actual.lineFraction - expected.lineFraction) < 0.000001)
        }
    }

    private func withSyntheticWindow(_ check: @MainActor (ReadingWindow) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-Host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Synthetic.txt")
        let text = "Chapter 1 UI_HOST\n" + (1...300).map { "UI_HOST_LINE_\($0) Synthetic reader viewport restoration content.\n" }.joined()
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let prepared = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = prepared else { Issue.record("Synthetic UTF-8 BOM unexpectedly required selection"); return }
        let reader = try await service.openReader(id: receipt.book.id, budget: ReaderStoragePolicy.budget())
        do {
            let anchor = ReadingAnchor(bookID: receipt.book.id, versionID: receipt.book.versionID,
                rawByteOffset: reader.source.metadata.bomByteCount)
            let rendered = try await reader.window(around: anchor, width: 350, preferences: reader.preferences)
            try check(rendered)
            try await reader.close()
        } catch {
            // Cleanup of this disposable fixture only; retain the primary test failure.
            try? await reader.close()
            throw error
        }
    }
}
