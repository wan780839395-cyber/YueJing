import Foundation
import GRDB

enum StoryGenerationRows {
    static func origins(sessionKey: String, in db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT o.turnID, o.modelName FROM storyModelOrigins o JOIN storyTurns t ON t.id=o.turnID WHERE t.sessionID=?
            """, arguments: [sessionKey])
        var result: [String: String] = [:]
        for row in rows { let key: String = row["turnID"]; result[key] = row["modelName"] as String }
        return result
    }

    static func check(_ d: StoryGenerationDraft, in db: Database) throws {
        try Task.checkCancellation()
        let s = d.session
        guard (0..<64).contains(d.expectedCount), let _ = try Int.fetchOne(db, sql: """
            SELECT 1 FROM storySessions s JOIN books b ON b.id=s.bookID AND b.versionID=s.versionID
            WHERE s.id=? AND s.bookID=? AND s.versionID=? AND s.presetID IS ?
              AND (SELECT COUNT(*) FROM storyTurns t WHERE t.sessionID=s.id)=?
            """, arguments: [s.id.uuidString, s.bookID, s.versionID, s.presetID, d.expectedCount]) else {
            throw StoryTurnError.staleCount
        }
        try StoryMemoryRows.checkMemoryRevision(sessionID: s.id, revision: d.memoryRevision, in: db)
    }

    static func commit(_ d: StoryGenerationDraft, text: String, in db: Database) throws -> StoryTurn {
        try check(d, in: db)
        let t = StoryTurn(id: d.id, sequence: d.expectedCount + 1, action: d.action, narration: text, modelName: d.model)
        try db.execute(sql: """
            INSERT INTO storyTurns(id,sessionID,sequence,action,narration,consequence) VALUES(?,?,?,?,?,?)
            """, arguments: [t.id.uuidString, d.session.id.uuidString, t.sequence, t.action, t.narration, String(text.suffix(80))])
        // v14 enqueues the pending job via the origin INSERT trigger in this writer transaction.
        try db.execute(sql: """
            INSERT INTO storyModelOrigins(turnID,modelName) VALUES(?,?)
            """, arguments: [t.id.uuidString, d.model])
        try Task.checkCancellation()
        return t
    }
}
