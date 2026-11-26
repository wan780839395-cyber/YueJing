import Foundation
import GRDB

private enum MemoryContextError: LocalizedError {
    case gaps, slots

    var errorDescription: String? {
        switch self {
        case .gaps: return "未整理回合的原文超过预算，请先补齐本局待办，再重新准备生成。"
        case .slots: return "本局有效记忆超过上下文预算，未删减现状，也未发送请求。"
        }
    }
}

enum StoryMemoryRows {
    // One row for a live session (including a session with no turns), none for a deleted branch.
    // Done jobs are never reopened. The count is therefore a revision even for empty extractions.
    private static let snapshotSQL = """
        SELECT count(t.id) AS turns, count(CASE WHEN j.state='done' THEN 1 END) AS revision
        FROM storySessions s JOIN books b ON b.id=s.bookID AND b.versionID=s.versionID
        LEFT JOIN storyTurns t ON t.sessionID=s.id LEFT JOIN storyMemoryJobs j ON j.turnID=t.id
        WHERE s.id=? GROUP BY s.id
        """
    private static let pendingSQL = """
        SELECT t.id,t.sequence,t.action,t.narration,o.modelName FROM storyTurns t
        JOIN storyMemoryJobs j ON j.turnID=t.id JOIN storyModelOrigins o ON o.turnID=t.id
        WHERE t.sessionID=? AND j.state='pending' ORDER BY t.sequence
        """
    private static let admissionSQL = """
        SELECT j.state FROM storyMemoryJobs j JOIN storyTurns t ON t.id=j.turnID
        JOIN storySessions s ON s.id=t.sessionID JOIN books b ON b.id=s.bookID AND b.versionID=s.versionID
        WHERE s.id=? AND t.id=? AND CAST(t.narration AS BLOB)=?
        """
    private static let eventSQL = """
        INSERT INTO storyMemoryEvents(turnID,kind,subject,value,evidence) VALUES(?,?,?,?,?)
        """
    private static let finishSQL = """
        UPDATE storyMemoryJobs SET state='done' WHERE turnID=? AND state='pending'
        """
    private static let latestSQL = """
        WITH ranked AS (
            SELECT e.kind,e.subject,e.value,t.sequence,
                row_number() OVER (PARTITION BY e.kind,e.subject ORDER BY t.sequence DESC) AS n
            FROM storyTurns t JOIN storyMemoryEvents e ON e.turnID=t.id JOIN storyMemoryJobs j ON j.turnID=t.id
            WHERE t.sessionID=? AND j.state='done'
        ) SELECT kind,subject,value,sequence FROM ranked WHERE n=1 ORDER BY kind,subject
        """
    private static let gapsSQL = """
        SELECT t.sequence, CASE WHEN t.sequence < ? AND length(CAST(t.narration AS BLOB)) <= ?
            THEN t.narration END AS original FROM storyTurns t JOIN storyMemoryJobs j ON j.turnID=t.id
        WHERE t.sessionID=? AND j.state='pending' ORDER BY t.sequence
        """
    private static let historySQL = """
        SELECT t.sequence,e.kind,e.subject,e.evidence FROM storyTurns t JOIN storyMemoryEvents e ON e.turnID=t.id
        JOIN storyMemoryJobs j ON j.turnID=t.id WHERE t.sessionID=? AND j.state='done' AND t.sequence < ?
        ORDER BY (instr(?,e.subject)>0 OR instr(?,e.value)>0) DESC,t.sequence DESC,e.kind,e.subject LIMIT 4
        """

    private static func snapshot(_ key: String, in db: Database) throws -> (turns: Int, revision: Int) {
        try Task.checkCancellation()
        guard let row = try Row.fetchOne(db, sql: snapshotSQL, arguments: [key]) else {
            throw StoryTurnError.unavailableSession
        }
        return (row["turns"], row["revision"])
    }

    static func checkMemoryRevision(sessionID: UUID, revision: Int, in db: Database) throws {
        guard try snapshot(sessionID.uuidString, in: db).revision == revision else { throw StoryTurnError.staleCount }
    }

    static func pending(_ sessionID: UUID, in db: Database) throws -> [StoryTurn] {
        let key = sessionID.uuidString
        _ = try snapshot(key, in: db)
        return try Row.fetchAll(db, sql: pendingSQL, arguments: [key]).map { row in
            try Task.checkCancellation()
            guard let id = UUID(uuidString: row["id"]) else { throw StoryTurnError.storage }
            return StoryTurn(id: id, sequence: row["sequence"], action: row["action"],
                             narration: row["narration"], modelName: row["modelName"])
        }
    }

    static func apply(_ sessionID: UUID, turnID: UUID, narration: String, changes: [StoryMemoryFact], in db: Database) throws {
        try Task.checkCancellation()
        let key = turnID.uuidString
        guard let state = try String.fetchOne(db, sql: admissionSQL,
            arguments: [sessionID.uuidString, key, Data(narration.utf8)]) else { throw StoryTurnError.unavailableSession }
        try StoryMemoryFact.validate(changes, narration: narration)
        try Task.checkCancellation()
        if state == "done" { return } // First successful extraction wins, even if a later valid response differs.
        for fact in changes {
            try Task.checkCancellation()
            try db.execute(sql: eventSQL, arguments: [key, fact.kind, fact.subject, fact.value, fact.evidence])
        }
        try db.execute(sql: finishSQL, arguments: [key])
        guard db.changesCount == 1 else { throw StoryTurnError.staleCount }
        try Task.checkCancellation() // Throw inside the writer; never report cancellation after commit.
    }

    static func context(_ sessionID: UUID, action: String, recentStart: Int, in db: Database) throws -> StorySceneMemory {
        let key = sessionID.uuidString, state = try snapshot(key, in: db)
        guard recentStart == max(1, state.turns - 7) else { throw StoryTurnError.staleCount }
        let sectionBytes = 8 * 1024
        var entries: [StoryBriefEntry] = []; var currentBytes = 0, gapBytes = 0, quoteBytes = 0
        let latest = try Row.fetchCursor(db, sql: latestSQL, arguments: [key])
        while let row = try latest.next() {
            try Task.checkCancellation()
            let seq: Int = row["sequence"], kind: String = row["kind"], subject: String = row["subject"], value: String = row["value"]
            let line = "第\(seq)回合 · \(kind) · \(subject)：\(value)"
            currentBytes += 1 + line.utf8.count; guard currentBytes <= sectionBytes else { throw MemoryContextError.slots }
            let privateKnowledge = kind == "knowledge"
            entries.append(.init(privateKnowledge ? .characterKnowledge : .branchState, line, privateKnowledge ? "此人和此命题的最近核实记录" : "本分支此状态的最后一次有效变更", sequence: seq, holder: privateKnowledge ? subject.components(separatedBy: "｜").first : nil))
        }
        let pending = try Row.fetchCursor(db, sql: gapsSQL, arguments: [recentStart, sectionBytes, key])
        while let row = try pending.next() {
            try Task.checkCancellation()
            let seq: Int = row["sequence"]
            let line: String
            if seq >= recentStart { line = "第\(seq)回合：见最近回合原文。" }
            else {
                guard let original: String = row["original"] else { throw MemoryContextError.gaps }
                line = "第\(seq)回合原文：\n\(original)"
            }
            gapBytes += 1 + line.utf8.count; guard gapBytes <= sectionBytes else { throw MemoryContextError.gaps }
            entries.append(.init(.unresolved, line, "待整理幕：原文优先于较旧的状态", sequence: seq))
        }
        if entries.isEmpty { return .init(entries: [], revision: state.revision) }
        // Illustrations only: old evidence must never overwrite the latest slot, or imply shared knowledge.
        let history = try Row.fetchAll(db, sql: historySQL, arguments: [key, recentStart, action, action])
        for row in history {
            let seq: Int = row["sequence"], kind: String = row["kind"], subject: String = row["subject"]
            let quote = "第\(seq)回合 · \(kind) · \(subject)：「\(row["evidence"] as String)」"
            if quoteBytes + quote.utf8.count + 1 <= sectionBytes {
                quoteBytes += quote.utf8.count + 1
                entries.append(.init(.historicalQuote,quote,"窗口外已核实的原句；按行动匹配优先，再按幕次",sequence:seq,holder:kind == "knowledge" ? subject.components(separatedBy:"｜").first : nil))
            }
        }
        try Task.checkCancellation()
        return .init(entries: entries, revision: state.revision)
    }
}
