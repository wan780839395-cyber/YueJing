import Foundation
import TXTCore

public enum ReaderCacheDisposition: String, Equatable, Sendable { case diskHit, rebuilt }

/// Product policy, separate from file format. Engineering admission budgets, not measured RSS.
public enum ReaderStoragePolicy {
    public static func budget() throws -> DerivedBookBudget {
        // A 50MiB ASCII fixture needs ~160MiB before directory overhead. Two generations
        // require headroom; rejection preserves the original instead of loading an unbounded fallback.
        try DerivedBookBudget(maximumArtifactBytes: 256 * 1024 * 1024, maximumStoredBytes: 512 * 1024 * 1024,
            maximumMetadataBytes: 2 * 1024 * 1024, maximumWorkingBytes: 8 * 1024 * 1024,
            maximumReadUTF16: 8192, maximumChapterEntries: 32)
    }
    public static func failureMessage(_ error: Error) -> String {
        if let error = error as? LibraryError { return error.errorDescription ?? "读取未完成，原书和位置已保留。" }
        if let error = error as? DerivedStorageError {
            switch error {
            case .budgetExceeded: return "暂时无法准备这本书的阅读文件，可返回书架后重试。原书和已保存位置已保留。"
            case .versionMismatch: return "文字版本不匹配，未覆盖原书或已保存位置。"
            case .closed, .staleBuild: return "本次读取已结束，可重新打开。"
            default: return "派生数据暂不可用，可重试打开；原书和已保存位置已保留。"
            }
        }
        return "读取未完成，原书和已保存位置已保留。"
    }
}

/// One fresh reading session and one leased generation. Never contains a complete TXTDocument.
public actor OpenedReader {
    public nonisolated let book: LibraryBook
    public nonisolated let source: DerivedBookSource
    public nonisolated let reading: ReadingStart
    public nonisolated let preferences: ReaderPreferences
    public nonisolated let cacheDisposition: ReaderCacheDisposition
    private let store: LibraryStore
    private let engine: DerivedReadingLayoutEngine
    private var closed = false
    private var finalized = false
    private struct Finalization: Sendable { let id: UUID; let task: Task<Void, Error> }
    private var finalization: Finalization?

    init(book: LibraryBook, source: DerivedBookSource, reading: ReadingStart,
         preferences: ReaderPreferences, disposition: ReaderCacheDisposition, store: LibraryStore) {
        self.book = book; self.source = source; self.reading = reading
        self.preferences = preferences; self.cacheDisposition = disposition; self.store = store
        self.engine = DerivedReadingLayoutEngine(source: source)
    }
    deinit {
        let owner = store, session = reading.session, dataSource = source
        Task { try? await owner.finishReader(session: session, anchor: nil, sequence: 1, preferences: nil, preferencesSequence: 0); await dataSource.close() }
    }
    public func saveProgress(_ anchor: ReadingAnchor, sequence: Int64) async throws -> Bool {
        guard !closed else { return false }
        try Task.checkCancellation()
        return try await store.saveProgress(session: reading.session, anchor: anchor, sequence: sequence)
    }
    public func chapterPage(start: Int, limit: Int) async throws -> [TXTChapter] {
        guard !closed else { throw DerivedStorageError.closed }
        let values = try await source.chapters(start: start, limit: limit)
        try Task.checkCancellation(); guard !closed else { throw DerivedStorageError.closed }
        return values
    }
    public func window(around anchor: ReadingAnchor, width: Double, preferences: ReaderPreferences,
                       measure: ProcessingMeasurementObserver? = nil) async throws -> ReadingWindow {
        guard !closed else { throw DerivedStorageError.closed }
        let value = try await engine.window(around: anchor, width: width, preferences: preferences, measure: measure)
        try Task.checkCancellation(); guard !closed else { throw DerivedStorageError.closed }; return value
    }
    public func savePreferences(_ value: ReaderPreferences, sequence: Int64) async throws -> Bool {
        guard !closed else { return false }
        return try await store.saveReaderPreferences(value, session: reading.session, sequence: sequence)
    }
    public func close(anchor: ReadingAnchor? = nil, sequence: Int64 = 1,
                      preferences: ReaderPreferences? = nil, preferencesSequence: Int64 = 1) async throws {
        try await close(anchor: anchor, sequence: sequence, preferences: preferences,
                        preferencesSequence: preferencesSequence, inject: nil)
    }
    func close(anchor: ReadingAnchor? = nil, sequence: Int64 = 1,
               preferences: ReaderPreferences? = nil, preferencesSequence: Int64 = 1,
               inject: ReaderCloseInjection?) async throws {
        closed = true // Revoke new writes BEFORE any suspension, even when the final save fails.
        guard !finalized else { return }
        let pending: Finalization
        if let existing = finalization {
            pending = existing; try await inject?(.joined)
        } else {
            let owner = store, session = reading.session, dataSource = source
            let task = Task {
                do {
                    try await inject?(.started)
                    try await owner.finishReader(session: session, anchor: anchor, sequence: sequence,
                                                 preferences: preferences, preferencesSequence: preferencesSequence)
                    await dataSource.close()
                } catch { await dataSource.close(); throw error }
            }
            pending = Finalization(id: UUID(), task: task); finalization = pending
        }
        do {
            try await pending.task.value
            if finalization?.id == pending.id { finalized = true; finalization = nil }
        } catch {
            if finalization?.id == pending.id { finalization = nil }
            throw error
        }
    }
    public func releasePageCache() async { await source.releasePageCache() }
}

struct ReaderOpenPermit: Sendable { let bookID: String; let id: UUID }
enum ReaderOpenStep: Equatable, Sendable { case buildStarted, buildJoined, sourceReady, sessionStarted, preferencesLoaded }
typealias ReaderOpenInjection = @Sendable (ReaderOpenStep) async throws -> Void
enum ReaderCloseStep: Equatable, Sendable { case started, joined }
typealias ReaderCloseInjection = @Sendable (ReaderCloseStep) async throws -> Void

struct ReadingRouteStatistics: Sendable {
    var documentDecodes = 0
    var chapterBuilds = 0
    var importedDocumentReuses = 0
    var diskHits = 0
    var rebuilds = 0
}

extension OpenedReader {
    public func bookmarkPage(start: Int, request: BookmarkRequest) async throws -> ReadingBookmarkPage {
        try checkBookmarkRequest(request)
        let page = try await store.bookmarkPage(session: reading.session, start: start, request: request)
        try checkBookmarkRequest(request)
        return page
    }

    public func bookmark(at anchor: ReadingAnchor, request: BookmarkRequest) async throws -> ReadingBookmark? {
        let position = try await strictBookmarkAnchor(anchor, request: request)
        let value = try await store.bookmark(session: reading.session, anchor: position, request: request)
        try checkBookmarkRequest(request)
        return value
    }

    public func addBookmark(at anchor: ReadingAnchor, id: UUID = UUID(), request: BookmarkRequest) async throws -> ReadingBookmark {
        let position = try await strictBookmarkAnchor(anchor, request: request)
        // Optional metadata only: the bounded directory query cannot repair an invalid position.
        let directoryPage = try? await directory(around: position)
        try checkBookmarkRequest(request) // Also on metadata failure/cancellation.
        var title: String?
        if let page = directoryPage, let current = page.currentIndex,
           page.chapters.indices.contains(current - page.start) {
            title = page.chapters[current - page.start].title.map { String($0.prefix(80)) }
        }
        // No post-write checks: admission wins over a later UI cancellation or close.
        return try await store.addBookmark(session: reading.session, anchor: position, id: id,
                                           chapterTitle: title, request: request)
    }

    public func deleteBookmark(id: String, request: BookmarkRequest) async throws {
        try checkBookmarkRequest(request)
        try await store.deleteBookmark(session: reading.session, id: id, request: request)
    }

    public func renameBookmark(id: String, name: String, request: BookmarkRequest) async throws -> ReadingBookmark {
        try checkBookmarkRequest(request)
        // A rename changes only display metadata; it needs no source mapping or compatible stored version.
        return try await store.renameBookmark(session: reading.session, id: id, name: name, request: request)
    }

    public func bookmarkAnchor(id: String, request: BookmarkRequest) async throws -> ReadingAnchor {
        try checkBookmarkRequest(request)
        let value = try await store.bookmark(session: reading.session, id: id, request: request)
        try checkBookmarkRequest(request)
        guard let value, let anchor = value.anchor(matching: book) else { throw LibraryError.invalidAnchor }
        let position = try await strictBookmarkAnchor(anchor, request: request)
        // Mapping suspends: reload again so a deletion or superseding session cannot win unnoticed.
        let current = try await store.bookmark(session: reading.session, id: id, request: request)
        try checkBookmarkRequest(request)
        guard let current, current.hasSamePosition(as: value) else { throw LibraryError.invalidAnchor }
        return position
    }

    private func checkBookmarkRequest(_ request: BookmarkRequest) throws {
        guard !closed else { throw DerivedStorageError.closed }
        try request.check()
    }

    private func strictBookmarkAnchor(_ anchor: ReadingAnchor, request: BookmarkRequest) async throws -> ReadingAnchor {
        try checkBookmarkRequest(request)
        let metadata = source.metadata
        guard anchor.bookID == book.id, anchor.versionID == book.versionID, anchor.unit == "raw-byte-v1",
              anchor.bookID == reading.session.bookID, anchor.versionID == reading.session.versionID,
              metadata.bookID == book.id, metadata.versionID == book.versionID,
              anchor.rawByteOffset >= metadata.bomByteCount, anchor.rawByteOffset < metadata.byteCount else {
            throw LibraryError.invalidAnchor
        }
        let utf16 = try await source.utf16Offset(for: RawByteOffset(anchor.rawByteOffset))
        try checkBookmarkRequest(request)
        guard utf16.value >= 0, utf16.value < metadata.utf16Count else { throw LibraryError.invalidAnchor }
        let start = try await source.composedStart(at: utf16.value)
        try checkBookmarkRequest(request)
        guard start == utf16.value else { throw LibraryError.invalidAnchor }
        let raw = try await source.rawByteOffset(for: utf16)
        try checkBookmarkRequest(request)
        guard raw.value == anchor.rawByteOffset else { throw LibraryError.invalidAnchor }
        return ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: raw.value, lineFraction: 0)
    }
}
