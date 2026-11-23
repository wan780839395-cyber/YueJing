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
    public func searchBook(_ input: String) async throws -> BookSearchResults {
        let query = try BookSearchMatcher.query(input)
        try await requireSearchSession()
        let package = publication.package
        var hits: [BookSearchHit] = [], titles: [String: String] = [:]
        for item in package.navigation where titles[item.path] == nil && !item.title.isEmpty {
            titles[item.path] = String(item.title.prefix(120))
        }
        for (index, path) in package.spine.enumerated() {
            await Task.yield()
            try Task.checkCancellation()
            guard !closed else { throw EPUBError.staleSession }
            guard let nodes = try package.nodes(at: path) else { throw EPUBError.corruptResource }
            for (node, text) in nodes.enumerated() {
                let matches = try BookSearchMatcher.matches(in: text, query: query, limit: BookSearchMatcher.limit + 1 - hits.count)
                for match in matches {
                    guard hits.count < BookSearchMatcher.limit else {
                        try await requireSearchSession()
                        return BookSearchResults(hits: hits, hasMore: true)
                    }
                    let position = EPUBReadingPosition(bookID: book.id, versionID: package.versionID, path: path,
                                                       node: node, utf16Offset: match.offset)
                    hits.append(BookSearchHit(chapterTitle: titles[path] ?? "第 \(index + 1) 节", snippet: match.snippet,
                                              location: .epub(position)))
                }
            }
        }
        try await requireSearchSession()
        return BookSearchResults(hits: hits, hasMore: false)
    }

    private func requireSearchSession() async throws {
        try Task.checkCancellation()
        guard !closed, let current = try await store.book(id: book.id),
              current.activeSession == reading.session.id, current.versionID == book.versionID,
              !closed else { throw EPUBError.staleSession }
        try Task.checkCancellation()
    }

    public func resolveSearchHit(_ hit: BookSearchHit) async throws -> EPUBReadingPosition {
        try await requireSearchSession()
        guard case .epub(let position) = hit.location else { throw EPUBError.invalidPosition }
        try position.validate(in: publication.package)
        return position
    }

    public func bookmarks() async throws -> [EPUBBookmark] {
        guard !closed else { throw EPUBError.staleSession }
        return try await store.epubBookmarks(session: reading.session)
    }

    /// Returns false only for an existing text anchor. A stale callback is an error.
    public func addBookmark(_ position: EPUBReadingPosition, title: String, token: EPUBNavigationToken) async throws -> Bool {
        guard !closed else { throw EPUBError.staleSession }
        return try await store.addEPUBBookmark(session: reading.session, position: position, title: title, token: token)
    }

    public func deleteBookmark(id: String) async throws {
        guard !closed else { throw EPUBError.staleSession }
        try await store.deleteEPUBBookmark(session: reading.session, id: id)
    }

    /// Resolves against the active package; neither begins navigation nor saves progress.
    public func bookmarkPosition(id: String) async throws -> EPUBReadingPosition {
        guard !closed else { throw EPUBError.staleSession }
        return try await store.epubBookmarkPosition(session: reading.session, id: id)
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
