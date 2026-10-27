import Foundation
import GRDB

/// SQLite and managed-file commits are serialized here, independently of UI cancellation tasks.
public actor LibraryStore {
    private enum Ticket { case open, cancelled, committed(ImportReceipt) }
    private let queue: DatabaseQueue
    private let root: URL
    private var tickets: [UUID: Ticket] = [:]
    private var closedSessions: Set<String> = []

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
            if url.pathExtension == "txt", Self.isBookID(id), !bookIDs.contains(id) { try files.removeItem(at: url) }
        }
        for url in try files.contentsOfDirectory(at: root.appendingPathComponent("Imports"), includingPropertiesForKeys: nil) {
            if url.pathExtension == "txt", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
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
