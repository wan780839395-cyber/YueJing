import Foundation
import GRDB

public enum StoryRoleKind: String, Codable, Hashable, Sendable { case canon, original }

/// A local branch, never a reading session. The opening is a bounded original excerpt, not generated prose.
public struct StorySession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let bookID: String
    public let versionID: String
    public let bookTitle: String
    public let roleKind: StoryRoleKind
    public let roleName: String
    public let premise: String
    public let opening: String
    public let presetID: String?
    public let createdAt: Date
}

public enum StoryLaunchError: Error, LocalizedError {
    case invalidRole, missingOpening, unreadableSave
    public var errorDescription: String? {
        switch self {
        case .invalidRole: return "角色名需为 1–60 字，身份说明不能超过 400 字。"
        case .missingOpening: return "无法取得这本书的开篇文字，尚未创建故事。"
        case .unreadableSave: return "本地故事记录无法读取，原记录已保留。"
        }
    }
}

extension LibraryService {
    public func startStory(book: LibraryBook, roleKind: StoryRoleKind, roleName: String,
                           premise: String, presetID: String? = nil) async throws -> StorySession {
        let name = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = premise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, detail.count <= 400 else { throw StoryLaunchError.invalidRole }
        try Task.checkCancellation()
        let excerpt = try await storyOpening(for: book).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { throw StoryLaunchError.missingOpening }
        let session = StorySession(id: UUID(), bookID: book.id, versionID: book.versionID, bookTitle: book.title,
                                   roleKind: roleKind, roleName: name, premise: detail,
                                   opening: excerpt, presetID: presetID, createdAt: Date())
        try await store.commitStory(session, for: book)
        return session
    }
}

// Keep DB access behind LibraryStore's existing actor and writer transaction. UUIDs are explicitly TEXT.
enum StoryRows {
    static func insert(_ s: StorySession, for requested: LibraryBook, in db: Database) throws {
        try Task.checkCancellation()
        guard let actual = try LibraryBook.fetchOne(db, key: requested.id), actual.versionID == requested.versionID,
              actual.format == requested.format, actual.addedAt == requested.addedAt else { throw LibraryError.missingBook }
        try db.execute(sql: """
            INSERT INTO storySessions(id, bookID, versionID, bookTitle, roleKind, roleName, premise, opening, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [s.id.uuidString, s.bookID, s.versionID, s.bookTitle, s.roleKind.rawValue,
                              s.roleName, s.premise, s.opening, s.createdAt.timeIntervalSinceReferenceDate])
        if let id = s.presetID { try StoryPresetRows.bind(id, session: s.id, in: db) }
        try Task.checkCancellation()
    }

    static func list(in db: Database) throws -> [StorySession] {
        try Row.fetchAll(db, sql: """
            SELECT s.* FROM storySessions AS s JOIN books AS b ON b.id=s.bookID AND b.versionID=s.versionID
            ORDER BY s.createdAt DESC, s.id
            """).map { row in
            guard let id = UUID(uuidString: row["id"]), let kind = StoryRoleKind(rawValue: row["roleKind"]) else {
                throw StoryLaunchError.unreadableSave
            }
            return StorySession(id: id, bookID: row["bookID"], versionID: row["versionID"], bookTitle: row["bookTitle"],
                                roleKind: kind, roleName: row["roleName"], premise: row["premise"], opening: row["opening"],
                                presetID: row["presetID"], createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"]))
        }
    }
}
