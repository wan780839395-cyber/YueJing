import Foundation

public actor OpenedEPUBReader {
    public nonisolated let book: LibraryBook
    public nonisolated let publication: EPUBPublication
    public nonisolated let reading: EPUBReadingStart
    public nonisolated let preferences: ReaderPreferences
    public nonisolated let reusedResources: Bool
    public nonisolated let openingTimings: EPUBOpeningTimings
    private let store: LibraryStore
    private let contentLease: EPUBContentLease
    private var closed = false
    private var closing: Task<Void, Error>?

    init(book: LibraryBook, publication: EPUBPublication, reading: EPUBReadingStart,
         preferences: ReaderPreferences, store: LibraryStore, contentLease: EPUBContentLease,
         reusedResources: Bool = false, openingTimings: EPUBOpeningTimings = .init()) {
        self.book = book; self.publication = publication; self.reading = reading
        self.preferences = preferences; self.store = store
        self.contentLease = contentLease
        self.reusedResources = reusedResources
        self.openingTimings = openingTimings
    }
    deinit {
        // A terminal task owns release from the instant it is installed.
        guard closing == nil else { return }
        let owner = store, session = reading.session, lease = contentLease
        Task {
            try? await owner.abandonEPUB(session: session)
            await lease.release()
        }
    }

    /// Pins only immutable files for an idle renderer; never retains this reading session.
    public func leaseForRenderer() async throws -> EPUBContentLease {
        guard !closed else { throw EPUBError.staleSession }
        return try await contentLease.duplicate()
    }

    public func beginNavigation(path: String) async throws -> EPUBNavigationToken {
        guard !closed else { throw EPUBError.staleSession }
        return try await store.beginEPUBNavigation(session: reading.session, path: path)
    }
    public func markReady(_ token: EPUBNavigationToken) async throws -> Bool {
        guard !closed else { return false }
        return try await store.markEPUBReady(session: reading.session, token: token)
    }
    public func save(_ position: EPUBReadingPosition, sequence: Int64, token: EPUBNavigationToken) async throws -> Bool {
        guard !closed else { return false }
        return try await store.saveEPUB(session: reading.session, position: position, sequence: sequence, token: token)
    }
    public func savePreferences(_ value: ReaderPreferences, sequence: Int64) async throws -> Bool {
        guard !closed else { return false }
        return try await store.saveReaderPreferences(value, session: reading.session, sequence: sequence)
    }
    /// Revoke an opening that was never presented; do not write a stale preferences snapshot.
    public func abandon() async throws {
        if let closing { try await closing.value; return }
        closed = true
        let owner = store, session = reading.session, lease = contentLease
        let operation = Task {
            do {
                try await owner.abandonEPUB(session: session)
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        }
        closing = operation
        try await operation.value
    }

    public func close(position: EPUBReadingPosition?, sequence: Int64, token: EPUBNavigationToken?,
                      preferences: ReaderPreferences) async throws {
        if let closing { try await closing.value; return }
        closed = true
        let owner = store, session = reading.session, lease = contentLease
        let cancelledAtStart = Task.isCancelled
        let operation = Task {
            do {
                try await owner.finishEPUB(session: session, position: position, sequence: sequence,
                                          token: token, preferences: preferences)
                if cancelledAtStart { throw CancellationError() }
                try Task.checkCancellation()
                await lease.finish(retain: true)
            } catch {
                await lease.release()
                throw error
            }
        }
        closing = operation
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
}
