import Foundation
import TXTCore

/// Leases one immutable generation. No original bytes, full text, session, settings or progress.
public actor DerivedBookSource {
    public nonisolated let metadata: DerivedBookMetadata
    private let store: LibraryStore
    private let lease: DerivedLease
    private var reader: DerivedPackReader?
    private var lastStatistics: DerivedReadStatistics

    init(url: URL, lease: DerivedLease, book: LibraryBook, budget: DerivedBookBudget, store: LibraryStore) throws {
        let value = try DerivedPackReader(url: url, pointer: lease.pointer, book: book, budget: budget)
        guard let encoding = book.encoding else { value.close(); throw LibraryError.invalidEncoding }
        metadata = DerivedBookMetadata(bookID: book.id, versionID: book.versionID, encoding: encoding,
            bomByteCount: value.manifest.bomBytes, byteCount: book.byteCount, utf16Count: book.utf16Count,
            chapterCount: value.manifest.chapters)
        self.store = store; self.lease = lease; self.reader = value; self.lastStatistics = value.statistics
    }
    deinit {
        // Explicit close is deterministic. This only releases a forgotten lease after actor destruction.
        let owner = store, token = lease
        Task { await owner.releaseDerivedLease(token) }
    }
    public func close() async {
        if let reader { lastStatistics = reader.statistics }
        reader?.close(); reader = nil; await store.releaseDerivedLease(lease)
    }
    public func releasePageCache() { reader?.clearCache() }
    public func statistics() -> DerivedReadStatistics {
        if let reader { return reader.statistics }
        return DerivedReadStatistics(payloadBytesRead: lastStatistics.payloadBytesRead, pageLoads: lastStatistics.pageLoads,
            cacheHits: lastStatistics.cacheHits, retainedLogicalBytes: 0, maximumWorkingBytes: lastStatistics.maximumWorkingBytes)
    }
    public func text(in range: UTF16Range) async throws -> DerivedTextFragment {
        try await perform { try $0.text(range) }
    }
    public func utf16Offset(for raw: RawByteOffset) async throws -> UTF16Offset {
        try await perform { try $0.exact(raw.value, raw: true).utf16 }
    }
    public func rawByteOffset(for utf16: UTF16Offset) async throws -> RawByteOffset {
        try await perform { try $0.exact(utf16.value, raw: false).rawByte }
    }
    public func composedStart(at utf16: Int) async throws -> Int {
        try await perform { try $0.composedStart(utf16) }
    }
    public func chapters(start: Int, limit: Int) async throws -> [TXTChapter] {
        try await perform { try $0.chapters(start: start, limit: limit) }
    }
    private func perform<T: Sendable>(_ action: (DerivedPackReader) throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard let reader else { throw DerivedStorageError.closed }
        do { return try action(reader) }
        catch {
            let invalidate: Bool
            if let failure = error as? DerivedStorageError { invalidate = failure == .corruptArtifact }
            else { invalidate = error is CocoaError || error is POSIXError }
            if invalidate {
                lastStatistics = reader.statistics
                self.reader = nil; reader.close()
                try? await store.invalidateDerived(lease.pointer)
                await store.releaseDerivedLease(lease)
            }
            throw error
        }
    }
}
