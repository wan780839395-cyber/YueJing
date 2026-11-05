import Foundation

public actor OpenedEPUBReader {
    public nonisolated let book: LibraryBook
    public nonisolated let publication: EPUBPublication
    public nonisolated let reading: EPUBReadingStart
    public nonisolated let preferences: ReaderPreferences
    public nonisolated let reusedResources: Bool
    private let store: LibraryStore
    private var closed = false
    private var closing: Task<Void, Error>?

    init(book: LibraryBook, publication: EPUBPublication, reading: EPUBReadingStart,
         preferences: ReaderPreferences, store: LibraryStore, reusedResources: Bool = false) {
        self.book = book; self.publication = publication; self.reading = reading
        self.preferences = preferences; self.store = store
        self.reusedResources = reusedResources
    }
    deinit {
        guard closing == nil else { return }
        let owner = store, session = reading.session, folder = publication.resourceRoot
        Task {
            try? await owner.abandonEPUB(session: session)
            try? FileManager.default.removeItem(at: folder)
        }
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
        let owner = store, session = reading.session, folder = publication.resourceRoot
        let operation = Task {
            defer { try? FileManager.default.removeItem(at: folder) }
            try await owner.abandonEPUB(session: session)
        }
        closing = operation
        try await operation.value
    }

    public func close(position: EPUBReadingPosition?, sequence: Int64, token: EPUBNavigationToken?,
                      preferences: ReaderPreferences) async throws {
        if let closing { try await closing.value; return }
        closed = true
        let owner = store, session = reading.session, folder = publication.resourceRoot
        let operation = Task {
            defer { try? FileManager.default.removeItem(at: folder) }
            try await owner.finishEPUB(session: session, position: position, sequence: sequence,
                                      token: token, preferences: preferences)
        }
        closing = operation
        try await operation.value
    }
}
