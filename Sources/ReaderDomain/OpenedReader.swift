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
