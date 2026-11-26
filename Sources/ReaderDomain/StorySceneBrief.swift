import Foundation

/// Sources attached locally to the exact prose used by the immutable generation draft.
/// Book identifiers and branch UUIDs are NOT serialized into the model payload.
public struct StoryBriefEntry: Sendable, Equatable {
    public enum Layer: String, Sendable { case canonOpening, playerIdentity, branchState, characterKnowledge, unresolved, historicalQuote, recentAction, recentNarration, playerAction }
    public let layer: Layer
    public let sequence: Int?
    public let holder: String?
    public let reason: String
    public let text: String
    init(_ layer: Layer, _ text: String, _ reason: String, sequence: Int? = nil, holder: String? = nil) {
        self.layer = layer; self.text = text; self.reason = reason; self.sequence = sequence; self.holder = holder
    }
}

struct StorySceneMemory: Sendable {
    let entries: [StoryBriefEntry]
    let revision: Int
    static let empty = Self(entries: [], revision: 0)
    var text: String {
        guard !entries.isEmpty else { return "" }
        var result = "本局已整理的现状（只约束本分支，不改写原著）："
        let sections: [(StoryBriefEntry.Layer, String)] = [(.branchState,"本局实际状态 / 承诺"),(.characterKnowledge,"人物认知：仅限列名的知情者。其认知不是客观真相，其他在场者不自动知情。"),(.unresolved,"尚有记忆缺口；此前现状可能已改变，按幕次核对原文。"),(.historicalQuote,"历史引文：只作回忆，不是现在的状态或公共知识。")]
        for (layer, heading) in sections {
            let rows = entries.filter { $0.layer == layer }; guard !rows.isEmpty else { continue }
            result += "\n" + heading + rows.map { "\n" + $0.text }.joined()
        }
        return result
    }
}

public struct StorySceneBrief: Sendable {
    public let sessionID: UUID
    public let bookID: String
    public let bookVersion: String
    public let entries: [StoryBriefEntry]
    let history: [StoryModelMessage]
    init(session: StorySession, turns: ArraySlice<StoryTurn>, memory: StorySceneMemory, action: String) {
        sessionID = session.id; bookID = session.bookID; bookVersion = session.versionID
        let identity = StoryBriefEntry(.playerIdentity, "我扮演\(session.roleKind == .canon ? "原著角色" : "原创角色")：\(session.roleName)。身份说明：\(session.premise)", "本局开局时由玩家指定，不是原著证据")
        let canon = StoryBriefEntry(.canonOpening, session.opening, "本书版本冻结的开篇节选；没有读取后文")
        var rows = [identity,canon] + memory.entries
        var messages = [StoryModelMessage(role:"user",content:identity.text + "\n原著依据（仅限开局节选，不代表所有人物知情）：\n" + canon.text)]
        if !memory.entries.isEmpty { messages.append(.init(role:"user",content:memory.text)) }
        for turn in turns {
            rows.append(.init(.recentAction,turn.action,"最近回合内的玩家意图，不证明成功",sequence:turn.sequence))
            rows.append(.init(.recentNarration,turn.narration,"最近回合已保存的分支正文",sequence:turn.sequence))
            messages += [.init(role:"user",content:turn.action),.init(role:"assistant",content:turn.narration)]
        }
        rows.append(.init(.playerAction,action,"本轮行动，结果尚未发生")); messages.append(.init(role:"user",content:action))
        entries = rows; history = messages
    }
    static let writerInstruction = "你负责执笔本局小说，不是与玩家聊天。让行动的后果发生在场景中，不替玩家做重大决定。仅引用已提供的原著依据；分支事件不改写原著。分别核对每个人当时能知道什么，听闻不等于证实，在场不等于认出。承诺、履行和失约是不同事件，证据不足时不替人物下结论。"
}
