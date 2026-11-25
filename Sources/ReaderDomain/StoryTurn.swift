import Foundation
import GRDB

/// A saved offline branch, not a passage from the book. Sequence starts at one.
public struct StoryTurn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let action: String
    public let narration: String
    public let modelName: String?

    init(id: UUID, sequence: Int, action: String, narration: String, modelName: String? = nil) {
        self.id = id; self.sequence = sequence; self.action = action
        self.narration = narration; self.modelName = modelName
    }
}

public enum StoryTurnError: Error, LocalizedError {
    case invalidAction, staleCount, unavailableSession, turnLimit, storage

    public var errorDescription: String? {
        switch self {
        case .invalidAction: return "行动需为 1–400 字。"
        case .staleCount: return "回合数不一致，请刷新后再行动。"
        case .unavailableSession: return "故事或对应版本的书籍已不可用。"
        case .turnLimit: return "这条离线分支已达到 64 回合上限。"
        case .storage: return "本地回合无法读取或保存。"
        }
    }

    // Do not expose GRDB diagnostics, SQL arguments, paths or player text.
    static func protect<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch is CancellationError { throw CancellationError() }
        catch let error as Self { throw error }
        catch { throw Self.storage }
    }
}

struct StoryTurnContext: Decodable, FetchableRecord {
    let roleName: String
    let roleKind: StoryRoleKind
    let premise: String
    let opening: String
}

enum StoryTurnRows {
    private struct State: Decodable, FetchableRecord {
        let n: Int
        let consequence: String?
    }

    private struct Saved: Decodable, FetchableRecord {
        let id: String
        let sequence: Int
        let action: String
        let narration: String
    }

    private static func context(_ key: String, in db: Database) throws -> StoryTurnContext {
        guard let context = try StoryTurnContext.fetchOne(db, sql: """
            SELECT s.roleName, s.roleKind, s.premise, s.opening
            FROM storySessions AS s JOIN books AS b ON b.id=s.bookID AND b.versionID=s.versionID
            WHERE s.id=?
            """, arguments: [key]) else { throw StoryTurnError.unavailableSession }
        guard !context.opening.isEmpty, context.opening.count <= StoryOpeningText.limit,
              !context.roleName.isEmpty, context.roleName.count <= 60,
              context.premise.count <= 400 else { throw StoryTurnError.storage }
        return context
    }

    static func list(sessionID: UUID, in db: Database) throws -> [StoryTurn] {
        try Task.checkCancellation()
        let key = sessionID.uuidString
        _ = try context(key, in: db)
        let records = try Saved.fetchAll(db, sql: """
            SELECT id, sequence, action, narration FROM storyTurns WHERE sessionID=? ORDER BY sequence ASC
            """, arguments: [key])
        let origins = try StoryGenerationRows.origins(sessionKey: key, in: db)
        return try records.enumerated().map { index, row in
            try Task.checkCancellation()
            guard let id = UUID(uuidString: row.id), row.sequence == index + 1 else { throw StoryTurnError.storage }
            return StoryTurn(id: id, sequence: row.sequence, action: row.action, narration: row.narration, modelName: origins[row.id])
        }
    }

    // Called inside DatabaseQueue.write: the catalog check, count compare, previous consequence
    // and insertion all see one writer transaction, including across different store instances.
    static func play(sessionID: UUID, expectedCount: Int, action: String, in db: Database) throws -> StoryTurn {
        try Task.checkCancellation()
        let action = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= 400 else { throw StoryTurnError.invalidAction }
        let key = sessionID.uuidString
        let context = try Self.context(key, in: db)
        guard let state = try State.fetchOne(db, sql: """
            SELECT history.n, t.consequence FROM
                (SELECT COUNT(*) AS n FROM storyTurns WHERE sessionID=? HAVING COUNT(*)=?) AS history
            LEFT JOIN storyTurns AS t ON t.sessionID=? AND t.sequence=history.n
            """, arguments: [key, expectedCount, key]) else { throw StoryTurnError.staleCount }
        guard state.n < 64 else { throw StoryTurnError.turnLimit }
        guard state.n == 0 || state.consequence != nil else { throw StoryTurnError.storage }
        let sequence = state.n + 1
        let beat = StoryTurnProse.compose(context, action: action, sequence: sequence, previous: state.consequence)
        let turn = StoryTurn(id: UUID(), sequence: sequence, action: action, narration: beat.narration)
        try db.execute(sql: """
            INSERT INTO storyTurns(id, sessionID, sequence, action, narration, consequence) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [turn.id.uuidString, key, sequence, action, turn.narration, beat.consequence])
        try Task.checkCancellation() // Throw before GRDB commits, not after returning to the caller.
        return turn
    }
}
