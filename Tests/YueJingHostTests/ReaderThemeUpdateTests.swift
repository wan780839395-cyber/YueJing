import Foundation
import ReaderDomain
import Testing
import UIKit
@testable import YueJing

// Direct VC calls with real engine windows; not a SwiftUI update or FPS measurement.
@MainActor
@Suite(.serialized)
struct ReaderThemeUpdateTests {
    @Test func sameThemeUpdatesAreIdempotentAndRealChangesStillApply() async throws {
        try await withWindows { first, _, _ in
            let controller = ReaderViewController()
            #expect(!controller.isViewLoaded)
            #expect(controller.setTheme(.paper)) // Initial nil must not skip the default paper theme.
            #expect(controller.isViewLoaded)
            try withHostedController(controller) { table in
                expectContainers(controller, table, theme: .paper)
                controller.apply(first, userNavigation: false)
                let anchor = controller.restorableAnchor(), offset = table.contentOffset
                let text = try visibleText(controller, table)
                #expect(!controller.setTheme(.paper))
                expectContainers(controller, table, theme: .paper)
                #expect(controller.setTheme(.dark))
                expectContainers(controller, table, theme: .dark)
                #expect(!controller.setTheme(.dark))
                #expect(controller.setTheme(.light))
                expectContainers(controller, table, theme: .light)
                #expect(!controller.setTheme(.light))
                #expect(controller.setTheme(.paper))
                expectContainers(controller, table, theme: .paper)
                #expect(controller.window?.id == first.id && controller.restorableAnchor() == anchor)
                let finalText = try visibleText(controller, table)
                #expect(table.contentOffset == offset && finalText == text)
                // Container changes do not recolor the old window's cells; apply owns that work.
            }
        }
    }

    @Test func sameThemeDoesNotPreventANewWindowFromApplying() async throws {
        try await withWindows { first, second, dark in
            #expect(first.id != second.id && second.id != dark.id)
            #expect(first.preferences.theme == .paper && second.preferences.theme == .paper)
            let controller = ReaderViewController()
            try withHostedController(controller) { table in
                #expect(controller.setTheme(.paper))
                controller.apply(first, userNavigation: false)
                let oldText = try visibleText(controller, table)
                #expect(!controller.setTheme(.paper))
                controller.apply(second, userNavigation: false)
                #expect(controller.window?.id == second.id && controller.restorableAnchor() == second.anchor)
                let newText = try visibleText(controller, table)
                #expect(newText != oldText)
                expectContainers(controller, table, theme: .paper)
                #expect(controller.setTheme(.dark))
                controller.apply(dark, userNavigation: false)
                #expect(controller.window?.id == dark.id && dark.preferences.theme == .dark)
                let darkText = try visibleText(controller, table)
                #expect(darkText == newText)
                let path = try #require(table.indexPathsForVisibleRows?.sorted().first)
                let cell = try #require(table.cellForRow(at: path))
                #expect(cell.backgroundColor == ReaderTheme.dark.background)
                #expect(cell.contentView.backgroundColor == ReaderTheme.dark.background)
                expectContainers(controller, table, theme: .dark)
            }
        }
    }

    private func expectContainers(_ controller: ReaderViewController, _ table: UITableView, theme: ReaderTheme) {
        #expect(controller.view.backgroundColor == theme.background)
        #expect(table.backgroundColor == theme.background)
    }

    private func visibleText(_ controller: ReaderViewController, _ table: UITableView) throws -> String {
        let rendered = try #require(controller.window)
        let path = try #require(table.indexPathsForVisibleRows?.sorted().first)
        let cell = try #require(table.cellForRow(at: path))
        // Existing stable accessibility ID, not a private canvas type or guessed subview index.
        let canvas = try #require(cell.contentView.subviews.first { $0.accessibilityIdentifier == "reader.text.canvas" })
        let text = try #require(canvas.accessibilityLabel)
        #expect(text == rendered.slices[path.row].lines.map(\.text).joined())
        #expect(!text.isEmpty)
        return text
    }

    private func withHostedController(_ controller: ReaderViewController, _ check: @MainActor (UITableView) throws -> Void) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        defer { host.isHidden = true; host.rootViewController = nil }
        host.rootViewController = controller; host.isHidden = false
        controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
        let table = try #require(controller.view.subviews.first { $0 is UITableView } as? UITableView)
        try check(table)
    }

    private func withWindows(_ check: @MainActor (ReadingWindow, ReadingWindow, ReadingWindow) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-Theme-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // Only this disposable synthetic fixture.
        let source = root.appendingPathComponent("Synthetic.txt")
        let firstChapter = "Chapter 1 UI_THEME_FIRST\n" + (1...200).map { "UI_THEME_FIRST_\($0) Synthetic first chapter content.\n" }.joined()
        let secondChapter = "Chapter 2 UI_THEME_SECOND\n" + (1...200).map { "UI_THEME_SECOND_\($0) Synthetic second chapter content.\n" }.joined()
        try (Data([0xEF, 0xBB, 0xBF]) + Data((firstChapter + secondChapter).utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let prepared = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = prepared else { Issue.record("Synthetic UTF-8 BOM unexpectedly required selection"); return }
        let reader = try await service.openReader(id: receipt.book.id, budget: ReaderStoragePolicy.budget())
        do {
            let firstAnchor = ReadingAnchor(bookID: receipt.book.id, versionID: receipt.book.versionID,
                rawByteOffset: reader.source.metadata.bomByteCount)
            let secondAnchor = ReadingAnchor(bookID: receipt.book.id, versionID: receipt.book.versionID,
                rawByteOffset: reader.source.metadata.bomByteCount + firstChapter.utf8.count)
            let paper = ReaderPreferences(theme: .paper)
            let first = try await reader.window(around: firstAnchor, width: 350, preferences: paper)
            let second = try await reader.window(around: secondAnchor, width: 350, preferences: paper)
            let dark = try await reader.window(around: secondAnchor, width: 350, preferences: ReaderPreferences(theme: .dark))
            try check(first, second, dark)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }
}
