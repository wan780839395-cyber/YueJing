import Foundation
import GRDB

/// SQLite and managed-file commits are serialized here, independently of UI cancellation tasks.
public actor LibraryStore {
    private enum Ticket { case open, cancelled, committed(ImportReceipt) }
    private let queue: DatabaseQueue
    private let root: URL
    private var tickets: [UUID: Ticket] = [:]
    private var closedSessions: Set<String> = []
    private var derivedBuilds: [String: String] = [:]
    private var derivedReservations: [String: Int] = [:]
    private var derivedLeases: [UUID: DerivedPointer] = [:]
    private var readerOpens: [String: UUID] = [:]
    private var readerPreferenceSequences: [String: Int64] = [:]
    private var epubSessions: [String: (package: EPUBPackage, token: EPUBNavigationToken?, ready: Bool)] = [:]

    public init(root: URL) throws {
        self.root = root
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("Books"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path)
        try LibrarySchema.migrator().migrate(queue)
        try queue.write { db in try db.execute(sql: "UPDATE books SET activeSession = NULL") }
        // Reconcile only recognized app-owned artifacts, and only after the database opened successfully.
        let bookIDs = try queue.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM books")) }
        for url in try files.contentsOfDirectory(at: root.appendingPathComponent("Books"), includingPropertiesForKeys: nil) {
            let id = url.deletingPathExtension().lastPathComponent
            if ["txt", "epub"].contains(url.pathExtension), Self.isBookID(id), !bookIDs.contains(id) { try files.removeItem(at: url) }
        }
        for url in try files.contentsOfDirectory(at: root.appendingPathComponent("Imports"), includingPropertiesForKeys: nil) {
            if ["txt", "epub", "epubwork"].contains(url.pathExtension), UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                try files.removeItem(at: url)
            }
        }
    }

    public func books() throws -> [LibraryBook] {
        try queue.read { db in try LibraryBook.fetchAll(db, sql: "SELECT * FROM books ORDER BY COALESCE(lastReadAt, addedAt) DESC, id") }
    }

    public func book(id: String) throws -> LibraryBook? {
        try queue.read { db in try LibraryBook.fetchOne(db, key: id) }
    }

    public func fileURL(bookID: String) throws -> URL {
        guard Self.isBookID(bookID) else { throw LibraryError.missingBook }
        return root.appendingPathComponent("Books").appendingPathComponent(bookID + ".txt")
    }

    public func stagingURL(ticket: UUID) -> URL {
        root.appendingPathComponent("Imports").appendingPathComponent(ticket.uuidString + ".txt")
    }

    public func beginImport(_ id: UUID) throws {
        if case .cancelled? = tickets[id] { throw CancellationError() }
        if tickets[id] == nil { tickets[id] = .open }
    }

    public func cancelImport(_ id: UUID) -> ImportCancellation {
        if case .committed(let receipt)? = tickets[id] { return .alreadyCommitted(receipt) }
        tickets[id] = .cancelled
        return .cancelled
    }

    /// No await within the decision/rename/transaction: cancellation and commit have one serial winner.
    public func commitImport(ticket: UUID, proposed: LibraryBook) throws -> ImportReceipt {
        switch tickets[ticket] {
        case .committed(let receipt)?: return receipt
        case .open?: break
        default: throw CancellationError()
        }
        try Task.checkCancellation()
        let staging = stagingURL(ticket: ticket), destination = try fileURL(bookID: proposed.id)
        let files = FileManager.default
        if let existing = try book(id: proposed.id) {
            try Task.checkCancellation()
            if !files.fileExists(atPath: destination.path) { try files.moveItem(at: staging, to: destination) }
            else if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            let receipt = ImportReceipt(book: existing, duplicate: true)
            tickets[ticket] = .committed(receipt)
            return receipt
        }
        guard !files.fileExists(atPath: destination.path) else { throw LibraryError.changedFile }
        try files.moveItem(at: staging, to: destination)
        do {
            try queue.write { db in
                try proposed.insert(db)
                try Task.checkCancellation()
            }
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
        // A cancellation after SQLite committed must return the committed truth, never "cancelled".
        let receipt = ImportReceipt(book: proposed, duplicate: false)
        tickets[ticket] = .committed(receipt)
        return receipt
    }

    public func beginReading(bookID: String, versionID: String) throws -> ReadingStart {
        let token = ReadingSession(id: UUID().uuidString, bookID: bookID, versionID: versionID)
        return try queue.write { db in
            guard let book = try LibraryBook.fetchOne(db, key: bookID) else { throw LibraryError.missingBook }
            guard book.versionID == versionID else { throw LibraryError.invalidAnchor }
            let old = try ProgressRow.fetchOne(db, key: bookID)
            let anchor = old?.anchor(matching: book)
            try db.execute(sql: "UPDATE books SET activeSession = ?, lastReadAt = ? WHERE id = ?",
                           arguments: [token.id, Date().timeIntervalSince1970, bookID])
            return ReadingStart(session: token, anchor: anchor, ignoredIncompatibleProgress: old != nil && anchor == nil)
        }
    }

    @discardableResult
    public func saveProgress(session: ReadingSession, anchor: ReadingAnchor, sequence: Int64) throws -> Bool {
        guard !closedSessions.contains(session.id) else { return false }
        return try queue.write { db in try Self.save(db, session: session, anchor: anchor, sequence: sequence) }
    }

    /// Final save and closing the session are one transaction; later callbacks cannot write through it.
    public func finishReading(session: ReadingSession, anchor: ReadingAnchor?, sequence: Int64) throws {
        // Closing authority is revoked even if the final anchor or SQLite write fails.
        closedSessions.insert(session.id)
        try queue.write { db in
            if let anchor { _ = try Self.save(db, session: session, anchor: anchor, sequence: sequence) }
            try db.execute(sql: "UPDATE books SET activeSession = NULL WHERE id = ? AND activeSession = ?",
                           arguments: [session.bookID, session.id])
        }
    }

    public func preferences() throws -> ReaderPreferences {
        try queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT data FROM preferences WHERE id = 1"),
                  let value = try? JSONDecoder().decode(ReaderPreferences.self, from: data) else { return ReaderPreferences() }
            return value.validated
        }
    }

    public func savePreferences(_ value: ReaderPreferences) throws {
        let data = try JSONEncoder().encode(value.validated)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO preferences(id, data) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data", arguments: [data])
        }
    }

    private static func save(_ db: Database, session: ReadingSession, anchor: ReadingAnchor, sequence: Int64) throws -> Bool {
        guard anchor.bookID == session.bookID, anchor.versionID == session.versionID, sequence > 0,
              let book = try LibraryBook.fetchOne(db, key: session.bookID), book.versionID == session.versionID,
              anchor.rawByteOffset >= 0, anchor.rawByteOffset <= book.byteCount else { throw LibraryError.invalidAnchor }
        guard book.activeSession == session.id else { return false }
        if let old = try ProgressRow.fetchOne(db, key: session.bookID), old.sessionID == session.id, sequence <= old.sequence { return false }
        try ProgressRow(bookID: anchor.bookID, versionID: anchor.versionID, unit: anchor.unit,
                        rawByteOffset: anchor.rawByteOffset, lineFraction: anchor.lineFraction,
                        sessionID: session.id, sequence: sequence).save(db)
        return true
    }

    private static func isBookID(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

// Independent cache authority. Existing import/progress decision methods above are unchanged.
extension LibraryStore {
    func reserveReaderOpen(bookID: String) throws -> ReaderOpenPermit {
        try Task.checkCancellation()
        guard try book(id: bookID) != nil else { throw LibraryError.missingBook }
        let permit = ReaderOpenPermit(bookID: bookID, id: UUID()); readerOpens[bookID] = permit.id
        return permit
    }
    func beginReader(_ permit: ReaderOpenPermit, versionID: String) throws -> ReadingStart {
        try Task.checkCancellation()
        guard readerOpens[permit.bookID] == permit.id else { throw CancellationError() }
        return try beginReading(bookID: permit.bookID, versionID: versionID)
    }
    func confirmReaderOpen(_ permit: ReaderOpenPermit, session: ReadingSession) throws {
        try Task.checkCancellation()
        guard readerOpens[permit.bookID] == permit.id,
              let book = try book(id: permit.bookID), book.activeSession == session.id,
              book.versionID == session.versionID else { throw CancellationError() }
    }
    func endReaderOpen(_ permit: ReaderOpenPermit) {
        if readerOpens[permit.bookID] == permit.id { readerOpens.removeValue(forKey: permit.bookID) }
    }
    func activeDerivedLeaseCount() -> Int { derivedLeases.count }
    func saveReaderPreferences(_ value: ReaderPreferences, session: ReadingSession, sequence: Int64) throws -> Bool {
        try Task.checkCancellation()
        guard !closedSessions.contains(session.id), sequence > (readerPreferenceSequences[session.id] ?? 0),
              let book = try book(id: session.bookID), book.activeSession == session.id,
              book.versionID == session.versionID else { return false }
        try savePreferences(value); readerPreferenceSequences[session.id] = sequence; return true
    }
    func finishReader(session: ReadingSession, anchor: ReadingAnchor?, sequence: Int64,
                      preferences: ReaderPreferences?, preferencesSequence: Int64) throws {
        closedSessions.insert(session.id)
        try queue.write { db in
            guard let book = try LibraryBook.fetchOne(db, key: session.bookID), book.activeSession == session.id else { return }
            if let anchor { _ = try Self.save(db, session: session, anchor: anchor, sequence: sequence) }
            if let preferences, preferencesSequence > (readerPreferenceSequences[session.id] ?? 0) {
                let data = try JSONEncoder().encode(preferences.validated)
                try db.execute(sql: "INSERT INTO preferences(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", arguments: [data])
            }
            try db.execute(sql: "UPDATE books SET activeSession=NULL WHERE id=? AND activeSession=?", arguments: [session.bookID, session.id])
        }
        readerPreferenceSequences.removeValue(forKey: session.id)
    }
    private var derivedRoot: URL { root.appendingPathComponent("Derived", isDirectory: true) }

    private func ensureDerivedRoot() throws {
        let files = FileManager.default
        if files.fileExists(atPath: derivedRoot.path) {
            let values = try derivedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw DerivedStorageError.corruptArtifact }
        } else { try files.createDirectory(at: derivedRoot, withIntermediateDirectories: false) }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = derivedRoot; try url.setResourceValues(values)
    }
    private func derivedURL(generation: String, staging: Bool) throws -> URL {
        guard DerivedBookFormat.isGeneration(generation) else { throw DerivedStorageError.corruptArtifact }
        return derivedRoot.appendingPathComponent(generation + (staging ? ".stage" : ".pack"))
    }
    private func pointer(_ db: Database, bookID: String) throws -> DerivedPointer? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM derivedArtifacts WHERE bookID = ?", arguments: [bookID]) else { return nil }
        let value = DerivedPointer(bookID: row["bookID"], versionID: row["versionID"], generation: row["generation"],
                                   manifestSHA256: row["manifestSHA256"], byteCount: row["byteCount"])
        guard DerivedBookFormat.isDigest(value.bookID), DerivedBookFormat.isDigest(value.versionID),
              DerivedBookFormat.isGeneration(value.generation), DerivedBookFormat.isDigest(value.manifestSHA256),
              value.byteCount >= DerivedBookFormat.headerBytes else { throw DerivedStorageError.corruptArtifact }
        return value
    }
    func reserveDerived(bookID: String, budget: DerivedBookBudget, evictUnleased: Bool = false) throws -> DerivedBuildPermit {
        try Task.checkCancellation()
        guard let book = try book(id: bookID) else { throw LibraryError.missingBook }
        try ensureDerivedRoot()
        let previous = try queue.read { db in try pointer(db, bookID: bookID)?.generation }
        var occupied = 0, visiblePacks: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: derivedRoot, includingPropertiesForKeys: nil) {
            let generation = url.deletingPathExtension().lastPathComponent
            guard DerivedBookFormat.isGeneration(generation), ["stage", "pack"].contains(url.pathExtension) else { continue }
            // A live stage is already charged by its full reservation.
            if url.pathExtension == "stage", derivedReservations[generation] != nil { continue }
            try DerivedBookFormat.regularFile(url)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw DerivedStorageError.corruptArtifact }
            occupied = try DerivedBookFormat.add(occupied, size)
            if url.pathExtension == "pack" { visiblePacks.insert(generation) }
        }
        // Unlinked files can remain allocated while an old reader holds its descriptor.
        var chargedLeases: Set<String> = []
        for lease in derivedLeases.values where !visiblePacks.contains(lease.generation) {
            if chargedLeases.insert(lease.generation).inserted { occupied = try DerivedBookFormat.add(occupied, lease.byteCount) }
        }
        for bytes in derivedReservations.values { occupied = try DerivedBookFormat.add(occupied, bytes) }
        let required = try DerivedBookFormat.add(occupied, budget.maximumArtifactBytes)
        if required > budget.maximumStoredBytes {
            guard evictUnleased else { throw DerivedStorageError.budgetExceeded }
            try evictReadingArtifacts(excluding: bookID, reclaim: required - budget.maximumStoredBytes)
            return try reserveDerived(bookID: bookID, budget: budget, evictUnleased: false)
        }
        let generation = UUID().uuidString.lowercased()
        derivedBuilds[bookID] = generation; derivedReservations[generation] = budget.maximumArtifactBytes
        return DerivedBuildPermit(book: book, generation: generation, previousGeneration: previous)
    }
    private func evictReadingArtifacts(excluding bookID: String, reclaim bytes: Int) throws {
        let candidates = try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT d.bookID FROM derivedArtifacts d JOIN books b ON b.id=d.bookID
                WHERE d.bookID<>? ORDER BY COALESCE(b.lastReadAt,b.addedAt),d.bookID
                """, arguments: [bookID])
        }
        var reclaimed = 0
        for id in candidates where reclaimed < bytes {
            try Task.checkCancellation()
            guard derivedBuilds[id] == nil,
                  let value = try queue.read({ db in try pointer(db, bookID: id) }),
                  !derivedLeases.values.contains(where: { $0.generation == value.generation }) else { continue }
            let url = try derivedURL(generation: value.generation, staging: false)
            var size = 0
            if FileManager.default.fileExists(atPath: url.path) {
                try DerivedBookFormat.regularFile(url)
                guard let actual = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw DerivedStorageError.corruptArtifact }
                size = actual
            }
            try invalidateDerived(value)
            if size > 0 { try FileManager.default.removeItem(at: url) }
            reclaimed = try DerivedBookFormat.add(reclaimed, size)
        }
        // Only cache pointers/recognized ordinary pack files above can be removed. No recursion,
        // original/progress mutation or unlimited exemption for previously read books.
    }
    func derivedStagingURL(_ permit: DerivedBuildPermit) throws -> URL { try derivedURL(generation: permit.generation, staging: true) }
    func abandonDerived(_ permit: DerivedBuildPermit) {
        if derivedBuilds[permit.book.id] == permit.generation { derivedBuilds.removeValue(forKey: permit.book.id) }
        derivedReservations.removeValue(forKey: permit.generation)
        // Exact app-generated file only; no recursive delete and never a Books/Imports path.
        if let url = try? derivedURL(generation: permit.generation, staging: true) { try? FileManager.default.removeItem(at: url) }
    }
    func publishDerived(_ prepared: PreparedDerivedBook, permit: DerivedBuildPermit,
                        inject: DerivedBuildInjection?) throws -> DerivedPointer {
        let value = prepared.pointer
        guard derivedBuilds[permit.book.id] == permit.generation, value.generation == permit.generation,
              value.bookID == permit.book.id, value.versionID == permit.book.versionID,
              value.byteCount <= (derivedReservations[permit.generation] ?? 0) else { throw DerivedStorageError.staleBuild }
        try Task.checkCancellation(); try inject?(.beforePublish); try Task.checkCancellation()
        let stage = try derivedURL(generation: permit.generation, staging: true)
        let destination = try derivedURL(generation: permit.generation, staging: false)
        try DerivedBookFormat.regularFile(stage)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DerivedStorageError.staleBuild }
        let file = try FileHandle(forReadingFrom: stage)
        defer { try? file.close() }
        guard try DerivedBookFormat.integer(file.seekToEnd()) == value.byteCount,
              try DerivedBookFormat.digest(DerivedBookFormat.read(file, offset: 0, count: DerivedBookFormat.headerBytes,
                  maximumBytes: DerivedBookFormat.headerBytes)) == value.manifestSHA256 else {
            throw DerivedStorageError.corruptArtifact
        }
        // Same directory rename; no heavy export or awaits within this decision/transaction.
        try FileManager.default.moveItem(at: stage, to: destination)
        do {
            try inject?(.renamed)
            try queue.write { db in
                guard let current = try LibraryBook.fetchOne(db, key: value.bookID), current.versionID == value.versionID,
                      current.encodingRaw == permit.book.encodingRaw, current.byteCount == permit.book.byteCount,
                      current.utf16Count == permit.book.utf16Count,
                      try pointer(db, bookID: value.bookID)?.generation == permit.previousGeneration else {
                    throw DerivedStorageError.staleBuild
                }
                try Task.checkCancellation()
                try db.execute(sql: """
                    INSERT INTO derivedArtifacts(bookID, versionID, generation, manifestSHA256, byteCount) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(bookID) DO UPDATE SET versionID=excluded.versionID, generation=excluded.generation,
                        manifestSHA256=excluded.manifestSHA256, byteCount=excluded.byteCount
                    """, arguments: [value.bookID, value.versionID, value.generation, value.manifestSHA256, value.byteCount])
            }
        } catch {
            // If commit outcome cannot be inspected, leave an orphan for reconciliation rather than deleting uncertain truth.
            let committed = try? queue.read { db in try pointer(db, bookID: value.bookID)?.generation == value.generation }
            if committed == false {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        derivedBuilds.removeValue(forKey: permit.book.id); derivedReservations.removeValue(forKey: permit.generation)
        try? inject?(.published) // After commit, cancellation/fault must not report an uncommitted outcome.
        return value
    }
    func leaseDerived(bookID: String) throws -> DerivedLease {
        guard let value = try queue.read({ db in try pointer(db, bookID: bookID) }) else { throw DerivedStorageError.missingArtifact }
        try ensureDerivedRoot()
        let id = UUID(); derivedLeases[id] = value
        return DerivedLease(id: id, pointer: value)
    }
    func derivedFileURL(_ lease: DerivedLease) throws -> URL {
        guard derivedLeases[lease.id] == lease.pointer else { throw DerivedStorageError.closed }
        return try derivedURL(generation: lease.pointer.generation, staging: false)
    }
    func releaseDerivedLease(_ lease: DerivedLease) { derivedLeases.removeValue(forKey: lease.id) }
    func invalidateDerived(_ value: DerivedPointer) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM derivedArtifacts WHERE bookID = ? AND generation = ? AND manifestSHA256 = ?",
                           arguments: [value.bookID, value.generation, value.manifestSHA256])
        }
    }
    /// Explicit, bounded-to-recognized-files reconciliation. Does not run in the old opening path.
    public func recoverDerivedStorage() throws {
        guard FileManager.default.fileExists(atPath: derivedRoot.path) else { return }
        try ensureDerivedRoot()
        let values = try queue.read { db in try String.fetchAll(db, sql: "SELECT bookID FROM derivedArtifacts") }
        var referenced: Set<String> = []
        for id in values {
            guard let value = try queue.read({ db in try pointer(db, bookID: id) }) else { continue }
            let url = try derivedURL(generation: value.generation, staging: false)
            if FileManager.default.fileExists(atPath: url.path) { referenced.insert(value.generation) }
            else { try invalidateDerived(value) }
        }
        referenced.formUnion(derivedLeases.values.map(\.generation))
        referenced.formUnion(derivedReservations.keys)
        for url in try FileManager.default.contentsOfDirectory(at: derivedRoot, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            guard ["stage", "pack"].contains(url.pathExtension), DerivedBookFormat.isGeneration(name), !referenced.contains(name) else { continue }
            try DerivedBookFormat.regularFile(url); try FileManager.default.removeItem(at: url)
        }
    }
}

private struct ProgressRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "progress"
    let bookID: String
    let versionID: String
    let unit: String
    let rawByteOffset: Int
    let lineFraction: Double
    let sessionID: String
    let sequence: Int64

    func anchor(matching book: LibraryBook) -> ReadingAnchor? {
        guard versionID == book.versionID, unit == "raw-byte-v1", rawByteOffset >= 0,
              rawByteOffset <= book.byteCount, lineFraction.isFinite, (0...1).contains(lineFraction) else { return nil }
        return ReadingAnchor(bookID: bookID, versionID: versionID, rawByteOffset: rawByteOffset, lineFraction: lineFraction)
    }
}

// Bookmark transactions never write reading state or derived-cache authority.
extension LibraryStore {
    private func admitBookmark(_ db: Database, session: ReadingSession, request: BookmarkRequest) throws -> LibraryBook {
        try request.check()
        guard !closedSessions.contains(session.id),
              let book = try LibraryBook.fetchOne(db, key: session.bookID),
              book.activeSession == session.id, book.versionID == session.versionID else { throw CancellationError() }
        // Last revocation check at admission. No await or post-commit cancellation check.
        try request.check()
        return book
    }

    func bookmarkPage(session: ReadingSession, start: Int, request: BookmarkRequest) throws -> ReadingBookmarkPage {
        guard start >= 0, start % ReadingBookmarkPage.pageSize == 0 else { throw LibraryError.invalidAnchor }
        return try queue.read { db in
            _ = try admitBookmark(db, session: session, request: request)
            // DatabaseQueue.read provides one snapshot for COUNT, clamping, and the bounded fetch.
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks WHERE bookID = ?", arguments: [session.bookID]) ?? 0
            let last = total == 0 ? 0 : (total - 1) / ReadingBookmarkPage.pageSize * ReadingBookmarkPage.pageSize
            let offset = min(start, last)
            let items = try ReadingBookmark.fetchAll(db, sql: """
                SELECT * FROM bookmarks WHERE bookID = ? ORDER BY createdAt DESC, id ASC LIMIT ? OFFSET ?
                """, arguments: [session.bookID, ReadingBookmarkPage.pageSize, offset])
            return ReadingBookmarkPage(start: offset, total: total, items: items)
        }
    }

    func bookmark(session: ReadingSession, anchor: ReadingAnchor, request: BookmarkRequest) throws -> ReadingBookmark? {
        try queue.read { db in
            let book = try admitBookmark(db, session: session, request: request)
            try Self.checkBookmarkPosition(anchor, book: book)
            return try Self.bookmark(db, at: anchor)
        }
    }

    func bookmark(session: ReadingSession, id: String, request: BookmarkRequest) throws -> ReadingBookmark? {
        try queue.read { db in
            _ = try admitBookmark(db, session: session, request: request)
            return try ReadingBookmark.fetchOne(db, sql: "SELECT * FROM bookmarks WHERE id = ? AND bookID = ?",
                                                arguments: [id, session.bookID])
        }
    }

    func addBookmark(session: ReadingSession, anchor: ReadingAnchor, id: UUID, chapterTitle: String?,
                     name: String = "", request: BookmarkRequest, afterCommit: (@Sendable () -> Void)? = nil) throws -> ReadingBookmark {
        try request.check()
        let customName = try ReadingBookmark.validatedCustomName(name)
        let result = try queue.write { db in
            let book = try admitBookmark(db, session: session, request: request)
            try Self.checkBookmarkPosition(anchor, book: book)
            // A reused request UUID may retry its position, but may never move another record.
            if let collision = try ReadingBookmark.fetchOne(db, key: id.uuidString) {
                guard collision.bookID == anchor.bookID, collision.versionID == anchor.versionID,
                      collision.unit == anchor.unit, collision.rawByteOffset == anchor.rawByteOffset else {
                    throw LibraryError.invalidAnchor
                }
            }
            if let existing = try Self.bookmark(db, at: anchor) { return existing }
            let value = ReadingBookmark(id: id.uuidString, bookID: book.id, versionID: book.versionID,
                rawByteOffset: anchor.rawByteOffset, createdAt: Date().timeIntervalSince1970,
                chapterTitleSnapshot: chapterTitle.map { String($0.prefix(80)) }, customName: customName)
            try value.insert(db)
            return value
        }
        afterCommit?() // Internal deterministic test seam; cannot throw or change committed truth.
        return result
    }

    func deleteBookmark(session: ReadingSession, id: String, request: BookmarkRequest) throws {
        try queue.write { db in
            _ = try admitBookmark(db, session: session, request: request)
            // Intentionally no bookmark-version predicate: incompatible records remain user-deletable.
            try db.execute(sql: "DELETE FROM bookmarks WHERE id = ? AND bookID = ?", arguments: [id, session.bookID])
        }
    }

    func renameBookmark(session: ReadingSession, id: String, name: String, request: BookmarkRequest,
                        afterCommit: (@Sendable () -> Void)? = nil) throws -> ReadingBookmark {
        try request.check()
        let customName = try ReadingBookmark.validatedCustomName(name)
        let result = try queue.write { db in
            _ = try admitBookmark(db, session: session, request: request)
            guard try ReadingBookmark.fetchOne(db, sql: "SELECT * FROM bookmarks WHERE id = ? AND bookID = ?",
                                              arguments: [id, session.bookID]) != nil else { throw LibraryError.invalidAnchor }
            try db.execute(sql: "UPDATE bookmarks SET customName = ? WHERE id = ? AND bookID = ?",
                           arguments: [customName, id, session.bookID])
            guard let updated = try ReadingBookmark.fetchOne(db, sql: "SELECT * FROM bookmarks WHERE id = ? AND bookID = ?",
                                                            arguments: [id, session.bookID]) else { throw LibraryError.invalidAnchor }
            return updated
        }
        afterCommit?() // Same committed-truth boundary as addition; no late cancellation check.
        return result
    }

    private static func checkBookmarkPosition(_ anchor: ReadingAnchor, book: LibraryBook) throws {
        guard anchor.bookID == book.id, anchor.versionID == book.versionID, anchor.unit == "raw-byte-v1",
              anchor.rawByteOffset >= 0, anchor.rawByteOffset < book.byteCount else { throw LibraryError.invalidAnchor }
    }
    private static func bookmark(_ db: Database, at anchor: ReadingAnchor) throws -> ReadingBookmark? {
        try ReadingBookmark.fetchOne(db, sql: """
            SELECT * FROM bookmarks WHERE bookID = ? AND versionID = ? AND unit = ? AND rawByteOffset = ?
            """, arguments: [anchor.bookID, anchor.versionID, anchor.unit, anchor.rawByteOffset])
    }
}

// EPUB has independent resources and progress units. Existing TXT transactions are not repurposed.
extension LibraryStore {
    public func epubFileURL(bookID: String) throws -> URL {
        guard Self.isBookID(bookID) else { throw LibraryError.missingBook }
        return root.appendingPathComponent("Books").appendingPathComponent(bookID + ".epub")
    }
    func epubStagingURL(ticket: UUID) -> URL {
        root.appendingPathComponent("Imports").appendingPathComponent(ticket.uuidString + ".epub")
    }
    func epubWorkURL(id: UUID) -> URL {
        root.appendingPathComponent("Imports").appendingPathComponent(id.uuidString + ".epubwork", isDirectory: true)
    }
    func epubCacheURL() -> URL {
        root.appendingPathComponent("EPUBCache", isDirectory: true)
            .appendingPathComponent("last-publication-v1", isDirectory: true)
    }
    func epubContentPoolURL() -> URL {
        root.appendingPathComponent("EPUBContent-v2", isDirectory: true)
    }


    func storedEPUBSnapshot(bookID: String) throws -> EPUBMetadataSnapshot {
        guard let book = try book(id: bookID), book.format == .epub else { throw LibraryError.missingBook }
        return try queue.read { db in
            guard let metadata = try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [bookID]) else {
                throw EPUBError.corruptResource
            }
            let snapshot = try EPUBMetadataSnapshot(metadata: metadata)
            let package = snapshot.package
            guard package.sourceSHA256 == bookID, package.versionID == book.versionID,
                  package.parserVersion == EPUBFormat.parserVersion else { throw EPUBError.corruptResource }
            return snapshot
        }
    }

    func commitEPUB(ticket: UUID, proposed: LibraryBook, package: EPUBPackage, cover: Data?) throws -> ImportReceipt {
        switch tickets[ticket] {
        case .committed(let receipt)?: return receipt
        case .open?: break
        default: throw CancellationError()
        }
        try Task.checkCancellation()
        guard proposed.format == .epub, proposed.id == package.sourceSHA256,
              proposed.versionID == package.versionID, package.parserVersion == EPUBFormat.parserVersion,
              !package.spine.isEmpty, (cover?.count ?? 0) <= 2 * 1024 * 1024 else { throw EPUBError.invalidPackage }
        let staging = epubStagingURL(ticket: ticket), destination = try epubFileURL(bookID: proposed.id)
        let files = FileManager.default
        guard try EPUBResourceStore.sourceDigest(staging) == proposed.id else { throw EPUBError.corruptResource }
        if let existing = try book(id: proposed.id) {
            guard existing.format == .epub, existing.versionID == proposed.versionID else { throw EPUBError.invalidPackage }
            if !files.fileExists(atPath: destination.path) { try files.moveItem(at: staging, to: destination) }
            else { try files.removeItem(at: staging) }
            let receipt = ImportReceipt(book: existing, duplicate: true)
            tickets[ticket] = .committed(receipt)
            return receipt
        }
        let metadata = try JSONEncoder().encode(package)
        guard !files.fileExists(atPath: destination.path) else { throw LibraryError.changedFile }
        try files.moveItem(at: staging, to: destination)
        do {
            try queue.write { db in
                try proposed.insert(db)
                try db.execute(sql: "INSERT INTO bookFormats(bookID,format) VALUES(?,'epub')", arguments: [proposed.id])
                try db.execute(sql: "INSERT INTO epubPackages(bookID,versionID,metadata,cover) VALUES(?,?,?,?)",
                               arguments: [proposed.id, proposed.versionID, metadata, cover])
                try Task.checkCancellation()
            }
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
        let receipt = ImportReceipt(book: proposed, duplicate: false)
        tickets[ticket] = .committed(receipt)
        return receipt
    }

    public func epubCover(bookID: String) throws -> Data? {
        try queue.read { db in
            let data = try Data.fetchOne(db, sql: "SELECT cover FROM epubPackages WHERE bookID=?", arguments: [bookID])
            return (data?.count ?? 0) <= 2 * 1024 * 1024 ? data : nil
        }
    }

    func beginEPUB(_ permit: ReaderOpenPermit, snapshot: EPUBMetadataSnapshot) throws -> EPUBReadingStart {
        try beginEPUBMeasured(permit, snapshot: snapshot, requestedAt: ContinuousClock.now).start
    }

    func beginEPUBMeasured(_ permit: ReaderOpenPermit, snapshot: EPUBMetadataSnapshot,
                           requestedAt: ContinuousClock.Instant) throws -> EPUBMeasuredReadingStart {
        let enteredAt = ContinuousClock.now
        let package = snapshot.package
        try Task.checkCancellation()
        guard readerOpens[permit.bookID] == permit.id, permit.bookID == package.sourceSHA256 else { throw CancellationError() }
        let session = ReadingSession(id: UUID().uuidString, bookID: permit.bookID, versionID: package.versionID)
        let queueStarted = ContinuousClock.now
        let transaction = try queue.write { db -> EPUBMeasuredReadingStart in
            var details = EPUBSessionBreakdown()
            details.record(.actorAdmission, since: requestedAt, until: enteredAt)
            details.record(.storeSetup, since: enteredAt, until: queueStarted)
            details.record(.databaseEntry, since: queueStarted)
            let storedBook = try details.measure(.bookRead) {
                try LibraryBook.fetchOne(db, key: permit.bookID)
            }
            guard let book = storedBook, book.format == .epub else { throw EPUBError.corruptResource }
            let format = try details.measure(.formatRead) {
                try String.fetchOne(db, sql: "SELECT format FROM bookFormats WHERE bookID=?", arguments: [permit.bookID])
            }
            guard format == "epub", book.versionID == package.versionID else { throw EPUBError.corruptResource }
            let storedMetadata = try details.measure(.metadataRead) {
                try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [book.id])
            }
            guard let metadata = storedMetadata else { throw EPUBError.corruptResource }
            details.metadataBytes = metadata.count
            guard details.measure(.metadataCompare, { snapshot.matches(metadata) }) else { throw EPUBError.corruptResource }
            let data = try details.measure(.progressRead) {
                try Data.fetchOne(db, sql: "SELECT anchor FROM epubProgress WHERE bookID=?", arguments: [book.id])
            }
            let decoded = details.measure(.progressDecode) {
                data.flatMap { try? JSONDecoder().decode(EPUBReadingPosition.self, from: $0) }
            }
            let valid = details.measure(.positionValidation) {
                decoded.flatMap { (try? $0.validate(in: package)) != nil ? $0 : nil }
            }
            try details.measure(.rowUpdate) {
                try db.execute(sql: "UPDATE books SET activeSession=?,lastReadAt=? WHERE id=?",
                               arguments: [session.id, Date().timeIntervalSince1970, book.id])
            }
            let start = EPUBReadingStart(session: session, position: valid, ignoredIncompatibleProgress: data != nil && valid == nil)
            return EPUBMeasuredReadingStart(start: start, details: details, finishedAt: ContinuousClock.now)
        }
        let transactionReturned = ContinuousClock.now
        var details = transaction.details
        details.record(.transactionReturn, since: transaction.finishedAt, until: transactionReturned)
        epubSessions[session.id] = (package, nil, false)
        details.record(.storePublish, since: transactionReturned)
        return EPUBMeasuredReadingStart(start: transaction.start, details: details, finishedAt: ContinuousClock.now)
    }

    func beginEPUBNavigation(session: ReadingSession, path: String) throws -> EPUBNavigationToken {
        try Task.checkCancellation()
        guard var authority = epubSessions[session.id], !closedSessions.contains(session.id),
              authority.package.spine.contains(path),
              let book = try book(id: session.bookID), book.activeSession == session.id else { throw EPUBError.staleSession }
        let token = EPUBNavigationToken(sessionID: session.id, path: path)
        authority.token = token; authority.ready = false; epubSessions[session.id] = authority
        return token
    }

    func markEPUBReady(session: ReadingSession, token: EPUBNavigationToken) throws -> Bool {
        guard var authority = epubSessions[session.id], authority.token == token,
              !closedSessions.contains(session.id),
              let book = try book(id: session.bookID), book.activeSession == session.id else { return false }
        authority.ready = true; epubSessions[session.id] = authority; return true
    }

    @discardableResult
    func saveEPUB(session: ReadingSession, position: EPUBReadingPosition, sequence: Int64,
                  token: EPUBNavigationToken) throws -> Bool {
        guard !closedSessions.contains(session.id), let authority = epubSessions[session.id],
              authority.token == token, authority.ready, token.path == position.path else { return false }
        try position.validate(in: authority.package)
        return try queue.write { db in try Self.saveEPUBRow(db, session: session, position: position, sequence: sequence) }
    }

    private static func saveEPUBRow(_ db: Database, session: ReadingSession, position: EPUBReadingPosition,
                                    sequence: Int64) throws -> Bool {
        guard position.bookID == session.bookID, position.versionID == session.versionID, sequence > 0,
              let book = try LibraryBook.fetchOne(db, key: session.bookID), book.format == .epub,
              book.versionID == session.versionID else { throw EPUBError.invalidPosition }
        guard book.activeSession == session.id else { return false }
        if let old = try Row.fetchOne(db, sql: "SELECT sessionID,sequence FROM epubProgress WHERE bookID=?", arguments: [book.id]),
           (old["sessionID"] as String) == session.id, sequence <= (old["sequence"] as Int64) { return false }
        let data = try JSONEncoder().encode(position)
        try db.execute(sql: """
            INSERT INTO epubProgress(bookID,versionID,unit,anchor,sessionID,sequence) VALUES(?,?,?,?,?,?)
            ON CONFLICT(bookID) DO UPDATE SET versionID=excluded.versionID,unit=excluded.unit,
                anchor=excluded.anchor,sessionID=excluded.sessionID,sequence=excluded.sequence
            """, arguments: [book.id, position.versionID, position.unit, data, session.id, sequence])
        return true
    }

    func finishEPUB(session: ReadingSession, position: EPUBReadingPosition?, sequence: Int64,
                    token: EPUBNavigationToken?, preferences: ReaderPreferences) throws {
        let authority = epubSessions.removeValue(forKey: session.id)
        closedSessions.insert(session.id)
        defer { readerPreferenceSequences.removeValue(forKey: session.id) }
        try queue.write { db in
            guard let book = try LibraryBook.fetchOne(db, key: session.bookID), book.activeSession == session.id else { return }
            if let position, let token, let authority, authority.ready, authority.token == token,
               position.path == token.path {
                try position.validate(in: authority.package)
                _ = try Self.saveEPUBRow(db, session: session, position: position, sequence: sequence)
            }
            let data = try JSONEncoder().encode(preferences.validated)
            try db.execute(sql: "INSERT INTO preferences(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", arguments: [data])
            try db.execute(sql: "UPDATE books SET activeSession=NULL WHERE id=? AND activeSession=?", arguments: [session.bookID, session.id])
        }
    }
}

extension LibraryStore {
    func abandonEPUB(session: ReadingSession) throws {
        epubSessions.removeValue(forKey: session.id)
        closedSessions.insert(session.id)
        readerPreferenceSequences.removeValue(forKey: session.id)
        try queue.write { db in
            try db.execute(sql: "UPDATE books SET activeSession=NULL WHERE id=? AND activeSession=?", arguments: [session.bookID, session.id])
        }
    }
}
