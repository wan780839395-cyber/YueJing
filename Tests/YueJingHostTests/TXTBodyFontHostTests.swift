import CoreGraphics
import Foundation
@testable import ReaderDomain
import SwiftUI
import Testing
import UIKit
@testable import YueJing

@Suite(.serialized) @MainActor
struct TXTBodyFontHostTests {
    #if DEBUG
    @Test func sharedPageSpecimenRendersTheSelectedFaceAtDraftSize() throws {
        let data = try EPUBFontLoadingHostTests.makeSyntheticGeometricFontData()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let face = try #require(CGFont(provider))
        func width(_ font: CGFont?, size: CGFloat) throws -> CGFloat {
            let view = ReaderSpecimenText(text: "AAAA", face: font, size: size, lineSpacing: 7).fixedSize()
            return try #require(ImageRenderer(content: view).uiImage).size.width
        }
        let original = try width(nil, size: 20)
        #expect(original > 0 && original < 100)
        #expect(abs(try width(face, size: 20) - 200) <= 1)
        #expect(abs(try width(face, size: 24) - 240) <= 1)
        #expect(try width(nil, size: 20) == original)
    }

    @Test func bodyCanvasPaintsTheWideAAndRestoresItsDefaultInk() throws {
        let bytes = try EPUBFontLoadingHostTests.makeSyntheticGeometricFontData()
        let face = try #require(TXTBodyFont(data: bytes))
        let line = try ReadingLine(range: .init(location: .init(0), length: 1), rawByteStart: 0,
                                   text: "A", top: 0, baseline: 30, height: 48)
        let slice = ReadingSlice(range: line.range, lines: [line], height: 48)
        let cell = ReadingCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: 120, height: 48)
        cell.layoutIfNeeded()
        func inkRight(_ face: TXTBodyFont?) throws -> Int {
            cell.render(slice, preferences: ReaderPreferences(fontSize: 20, theme: .light), bodyFont: face)
            let ctx = try #require(CGContext(data: nil, width: 120, height: 48, bitsPerComponent: 8,
                bytesPerRow: 120, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            cell.paintCanvasForTesting(cell.bounds, in: ctx)
            let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            return try #require((0..<120).last { x in (0..<48).contains { y in px[y * 120 + x] < 128 } })
        }
        let original = try inkRight(nil), wide = try inkRight(face)
        // Origin x=20; synthetic A's rightmost outline is at 2.4em (not just its advance).
        #expect((65...69).contains(wide))
        #expect(wide > original + 25)
        #expect(try inkRight(nil) == original)
    }
    #endif

    @Test func reflowAndReopenKeepScrolledTextWithSelectedAndRestoredFont() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let managed = root.appendingPathComponent("managed"), library = root.appendingPathComponent("fonts")
        let source = root.appendingPathComponent("Synthetic.txt"), ttf = root.appendingPathComponent("Wide.ttf")
        let prefix = "章首 🌙\n", text = prefix + String(repeating: "A", count: 10000)
        try (Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)).write(to: source)
        try EPUBFontLoadingHostTests.makeSyntheticGeometricFontData().write(to: ttf)
        let store = EPUBUserFontStore(root: library), font = try await store.importFont(from: ttf)
        weak var previousStore: LibraryStore?
        let bookID: String
        do {
            let db = try LibraryStore(root: managed); previousStore = db
            let service = LibraryService(store: db)
            let result = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
            guard case .completed(let receipt) = result else { Issue.record("BOM fixture did not import"); return }
            bookID = receipt.book.id
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        defer { host.isHidden = true; host.rootViewController = nil }

        func withReader<T>(_ check: @MainActor (ReaderViewModel, ReaderViewController) async throws -> T) async throws -> T {
            // A cold open starts only after prior asynchronous session cleanup releases SQLite.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while previousStore != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(previousStore == nil)
            let db = try LibraryStore(root: managed); previousStore = db
            let reopened = LibraryService(store: db)
            let m = ReaderViewModel(bookID: bookID, service: reopened,
                fontStore: EPUBUserFontStore(root: library), fontDefaults: defaults)
            let vc = ReaderViewController()
            host.rootViewController = vc; host.isHidden = false
            vc.view.frame = host.bounds; vc.view.layoutIfNeeded(); m.viewport.attach(vc)
            vc.onAnchor = { [weak m] in m?.visibleChanged($0, windowID: $1) }
            m.resized(390); await m.load()
            _ = try await applyNext(m, vc, after: nil)
            defer { host.rootViewController = nil }
            let value = try await check(m, vc)
            try #require(await m.close())
            return value
        }
        let (target, utf16, originalWidth, wideWidth) = try await withReader { m, vc in
            let initial = try #require(m.window), table = try #require(vc.view.subviews.compactMap { $0 as? UITableView }.first)
            vc.scrollViewWillBeginDragging(table)
            table.setContentOffset(CGPoint(x: 0, y: 529), animated: false)
            vc.scrollViewDidScroll(table); vc.scrollViewDidEndDragging(table, willDecelerate: false)
            let target = try #require(vc.restorableAnchor())
            try #require(target.rawByteOffset > 3 + prefix.utf8.count)
            let utf16 = prefix.utf16.count + target.rawByteOffset - 3 - prefix.utf8.count
            let originalWidth = maxLine(initial)
            m.selectBodyFont(font)
            let wide = try await applyNext(m, vc, after: initial.id)
            #expect(wide.anchor == target && wide.targetUTF16 == utf16 && vc.navigationTargetVisible)
            #expect(vc.restorableAnchor() == target && m.selectedBodyFontID == font.id)
            #expect(maxLine(wide) < originalWidth && maxLine(wide) == 7)
            return (target, utf16, originalWidth, maxLine(wide))
        }
        try await withReader { second, vc2 in
            let coldWide = try #require(second.window)
            #expect(second.selectedBodyFontID == font.id && maxLine(coldWide) == wideWidth)
            #expect(coldWide.targetUTF16 == utf16 && vc2.restorableAnchor() == target && vc2.navigationTargetVisible)
            second.selectBodyFont(nil)
            let restored = try await applyNext(second, vc2, after: coldWide.id)
            #expect(restored.targetUTF16 == utf16 && vc2.restorableAnchor() == target && vc2.navigationTargetVisible)
            #expect(maxLine(restored) == originalWidth && second.selectedBodyFontID == nil)
        }
        try await withReader { third, vc3 in
            let coldDefault = try #require(third.window)
            #expect(third.selectedBodyFontID == nil && maxLine(coldDefault) == originalWidth)
            #expect(coldDefault.targetUTF16 == utf16 && vc3.restorableAnchor() == target && vc3.navigationTargetVisible)
        }
    }

    private func maxLine(_ window: ReadingWindow) -> Int {
        window.slices.flatMap(\.lines).filter { $0.text.allSatisfy { $0 == "A" } }.map { $0.range.length }.max() ?? 0
    }
    private func applyNext(_ model: ReaderViewModel, _ vc: ReaderViewController, after old: UUID?) async throws -> ReadingWindow {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.window?.id == old && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let next = try #require(model.window)
        try #require(next.id != old)
        vc.apply(next, userNavigation: false); model.viewport.applied(vc); model.windowApplied(next.id)
        return next
    }
}
