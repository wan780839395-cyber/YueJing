import Foundation
import GRDB
import Testing
import TXTCore
@testable import ReaderDomain

@Suite(.serialized)
struct ProcessingReuseTests {
    private struct Fixture {
        let root: URL
        let store: LibraryStore
        let service: LibraryService
        init(limit: Int = 64 * 1024 * 1024) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-reuse-" + UUID().uuidString)
            store = try LibraryStore(root: root.appendingPathComponent("Managed"))
            service = LibraryService(store: store, processingCacheLimit: limit)
        }
        func clean() {
            guard root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
                  root.lastPathComponent.hasPrefix("YueJing-reuse-") else { return }
            try? FileManager.default.removeItem(at: root)
        }
        func install(_ text: String = "Chapter 1\nsynthetic reading content\n", name: String = "sample") async throws -> LibraryBook {
            let source = root.appendingPathComponent(name + ".txt")
            try Data(text.utf8).write(to: source)
            guard case .completed(let receipt) = try await service.prepareImport(url: source, ticket: UUID()) else {
                throw LibraryError.invalidEncoding
            }
            return receipt.book
        }
    }

    @Test func importedDocumentAndReopenedChaptersAreReusedWithFreshSessionAndProgress() async throws {
        let f = try Fixture(); defer { f.clean() }
        let book = try await f.install()
        let imported = await f.service.processingReuseStatistics()
        #expect(imported.decodeCalls == 1 && imported.chapterCalls == 0 && imported.retainedBytes > 0)
        let first = try await f.service.openBook(id: book.id)
        let anchor = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: 12)
        try await f.store.finishReading(session: first.reading.session, anchor: anchor, sequence: 1)
        let settings = ReaderPreferences(fontSize: 28, lineSpacing: 9, theme: .dark)
        try await f.store.savePreferences(settings)
        let second = try await f.service.openBook(id: book.id)
        let reused = await f.service.processingReuseStatistics()
        #expect(reused.decodeCalls == 1 && reused.chapterCalls == 1)
        #expect(reused.documentHits == 2 && reused.chapterHits == 1)
        #expect(first.reading.session.id != second.reading.session.id)
        #expect(second.reading.anchor == anchor)
        #expect(try await f.store.preferences() == settings)
        #expect(first.document.versionID == second.document.versionID)
        #expect(first.chapters.map(\.id) == second.chapters.map(\.id))
    }

    @Test func warmCacheStillRejectsSameSizeChangesMissingFilesAndWrongMetadata() async throws {
        let f = try Fixture(); defer { f.clean() }
        let book = try await f.install()
        _ = try await f.service.openBook(id: book.id)
        let file = try await f.store.fileURL(bookID: book.id)
        let original = try Data(contentsOf: file)
        var changed = original; changed[0] = 88
        #expect(changed.count == original.count)
        try changed.write(to: file, options: .atomic)
        await #expect(throws: LibraryError.self) { try await f.service.openBook(id: book.id) }
        let changedStats = await f.service.processingReuseStatistics()
        #expect(changedStats.retainedBytes == 0)
        try original.write(to: file, options: .atomic)
        _ = try await f.service.openBook(id: book.id)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: LibraryError.self) { try await f.service.openBook(id: book.id) }
        try original.write(to: file, options: .atomic)
        _ = try await f.service.openBook(id: book.id)
        let queue = try DatabaseQueue(path: f.root.appendingPathComponent("Managed/library.sqlite").path)
        try await queue.write { db in try db.execute(sql: "UPDATE books SET versionID = 'invalid' WHERE id = ?", arguments: [book.id]) }
        await #expect(throws: LibraryError.self) { try await f.service.openBook(id: book.id) }
        try await queue.write { db in try db.execute(sql: "UPDATE books SET versionID = ?, encodingRaw = ? WHERE id = ?",
            arguments: [book.versionID, TXTEncoding.gbk.rawValue, book.id]) }
        await #expect(throws: LibraryError.self) { try await f.service.openBook(id: book.id) }
        let final = await f.service.processingReuseStatistics()
        #expect(final.retainedBytes == 0)
    }

    @Test func memoryPressureAndCancellationEvictWithoutPublishingUncommittedImports() async throws {
        let f = try Fixture(); defer { f.clean() }
        let book = try await f.install()
        await f.service.releaseProcessingCache()
        let released = await f.service.processingReuseStatistics()
        #expect(released.retainedBytes == 0)
        _ = try await f.service.openBook(id: book.id)
        let reopened = await f.service.processingReuseStatistics()
        #expect(reopened.decodeCalls == 2 && reopened.retainedBytes > 0)
        let ticket = UUID(); _ = await f.service.cancelImport(ticket)
        let source = f.root.appendingPathComponent("cancelled.txt")
        try Data("other content".utf8).write(to: source)
        await #expect(throws: CancellationError.self) { try await f.service.prepareImport(url: source, ticket: ticket) }
        let ambiguous = f.root.appendingPathComponent("ambiguous.txt")
        try Data([0xC2, 0xA1]).write(to: ambiguous)
        let pending = UUID()
        guard case .choose = try await f.service.prepareImport(url: ambiguous, ticket: pending) else {
            Issue.record("Expected an uncommitted encoding choice"); return
        }
        let waiting = await f.service.processingReuseStatistics()
        #expect(waiting.retainedBytes == 0)
        _ = await f.service.cancelImport(pending)
        await #expect(throws: CancellationError.self) { try await f.service.confirmImport(ticket: pending, encoding: .utf8) }
        let cancelled = await f.service.processingReuseStatistics()
        #expect(cancelled.retainedBytes == 0)
        #expect(try await f.store.books().count == 1)
    }

    @Test func overBudgetFallsBackToOriginalProcessingOnEveryOpen() async throws {
        let f = try Fixture(limit: 1); defer { f.clean() }
        let book = try await f.install()
        let first = try await f.service.openBook(id: book.id)
        _ = try await f.service.openBook(id: book.id)
        let stats = await f.service.processingReuseStatistics()
        #expect(stats.decodeCalls == 3 && stats.chapterCalls == 2)
        #expect(stats.documentHits == 0 && stats.chapterHits == 0 && stats.retainedBytes == 0)
        #expect(first.document.estimatedRetainedBytes > first.document.originalBytes.count * 2)
    }

    @Test func switchingBooksAndDuplicateRepairDoNotReuseWrongContentOrEncoding() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try await f.install()
        let b = try await f.install("Chapter 2\ndifferent synthetic book\n", name: "other")
        _ = try await f.service.openBook(id: b.id)
        let before = await f.service.processingReuseStatistics()
        let opened = try await f.service.openBook(id: a.id)
        let switched = await f.service.processingReuseStatistics()
        #expect(switched.decodeCalls == before.decodeCalls + 1)
        #expect(opened.document.documentID == a.id)
        let source = f.root.appendingPathComponent("sample.txt")
        let file = try await f.store.fileURL(bookID: a.id)
        try FileManager.default.removeItem(at: file)
        guard case .completed(let repair) = try await f.service.prepareImport(url: source, ticket: UUID()) else {
            Issue.record("Expected duplicate repair"); return
        }
        #expect(repair.duplicate && repair.book.encodingRaw == a.encodingRaw && repair.book.versionID == a.versionID)
        let repaired = await f.service.processingReuseStatistics()
        #expect(repaired.retainedBytes == 0)
        _ = try await f.service.openBook(id: a.id)
        let final = await f.service.processingReuseStatistics()
        #expect(final.decodeCalls == repaired.decodeCalls + 1)
    }

    @Test func invalidatedGenerationCannotPublishOrClearNewerContent() async throws {
        let document = try await TXTProcessor().decode(Data("synthetic\n".utf8), using: .utf8)
        let book = LibraryBook(id: document.documentID, title: "synthetic", encodingRaw: document.encoding.rawValue,
            versionID: document.versionID, byteCount: document.originalBytes.count, utf16Count: document.utf16Count)
        var cache = ProcessedBookCache()
        let old = cache.begin(bookID: book.id)
        cache.invalidate()
        let stale = cache.retain(document, chapters: nil, book: book, token: old)
        #expect(!stale && cache.estimatedBytes == 0)
        let current = cache.begin(bookID: book.id)
        let kept = cache.retain(document, chapters: nil, book: book, token: current)
        let staleLookup = cache.lookup(book, token: old)
        cache.invalidate(ifCurrent: old)
        let ready = cache.lookup(book, token: current)
        #expect(kept && staleLookup == nil && ready != nil)
        #expect(cache.generation == current)
        let switched = cache.begin(bookID: "another-book")
        let late = cache.retain(document, chapters: nil, book: book, token: current)
        #expect(!late && cache.generation == switched && cache.estimatedBytes == 0)
    }
}
