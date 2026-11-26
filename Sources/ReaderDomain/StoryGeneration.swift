import Foundation

public struct StoryModelMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String
}

public struct StoryGenerationDraft: Identifiable, Sendable {
    public let id: UUID
    public let endpoint: URL
    public let model: String
    public let presetName: String?
    public let messages: [StoryModelMessage]
    public let parameters: [String: String]
    public let omittedTurns: Int
    let session: StorySession
    let expectedCount: Int
    let action: String
    let memoryRevision: Int
    let body: Data
}

public enum StoryGenerationError: Error, LocalizedError {
    case busy, unsupported, budget, incomplete
    public var errorDescription: String? {
        switch self {
        case .busy: return "此故事已有生成请求，请等待或取消。"
        case .unsupported: return "本局预设不能准确组装，未发送请求。"
        case .budget: return "本次请求或回复超过大小预算，不能继续。"
        case .incomplete: return "没有收到完整的故事正文，未保存回合。"
        }
    }
}

enum StoryGenerationBuilder {
    static func prepare(session: StorySession, turns: [StoryTurn], preset: StoryPresetVersion?, action raw: String,
                        configuration config: StoryModelConfiguration, memoryText: String = "", memoryRevision: Int = 0) throws -> StoryGenerationDraft {
        let action = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= 400 else { throw StoryTurnError.invalidAction }
        guard turns.count < 64 else { throw StoryTurnError.turnLimit }
        guard session.presetID == preset?.summary.id else { throw StoryGenerationError.unsupported }
        let recent = turns.suffix(8)
        let kind = session.roleKind == .canon ? "原著角色" : "原创角色"
        var history: [StoryModelMessage] = [.init(role: "user", content: "我扮演\(kind)：\(session.roleName)。身份说明：\(session.premise)\n本局原文开篇：\n\(session.opening)")]
        if !memoryText.isEmpty { history.append(.init(role: "user", content: memoryText)) }
        for turn in recent {
            history.append(.init(role: "user", content: turn.action))
            history.append(.init(role: "assistant", content: turn.narration))
        }
        history.append(.init(role: "user", content: action))
        var messages: [StoryModelMessage] = []
        if let preset {
            guard preset.summary.canSelect, preset.issues.isEmpty else { throw StoryGenerationError.unsupported }
            var inserted = false
            for entry in preset.entries where entry.enabled {
                if entry.isHistory {
                    guard !inserted, entry.identifier == "chatHistory" else { throw StoryGenerationError.unsupported }
                    messages += history; inserted = true
                } else {
                    guard ["user","assistant","system"].contains(entry.role), !entry.content.isEmpty else { throw StoryGenerationError.unsupported }
                    messages.append(.init(role: entry.role, content: entry.content))
                }
            }
            guard inserted else { throw StoryGenerationError.unsupported }
        } else {
            messages = [.init(role: "system", content: "根据开篇、角色和玩家行动，续写一幕连贯的小说正文。让行动带来具体后果，保留玩家下一步决定。不要将分支冒充原著事实。\n" + StoryMemoryProtocol.instruction)] + history
        }
        let parameters = preset?.parameters ?? [:]
        var payload: [String: Any] = ["model": config.model, "stream": true,
                                     "messages": messages.map { ["role": $0.role, "content": $0.content] }]
        for (key, rawValue) in parameters {
            switch key {
            case "max_tokens":
                guard let n = Int(rawValue), (1...2_147_483_647).contains(n) else { throw StoryGenerationError.unsupported }
                payload[key] = n
            case "temperature", "top_p", "frequency_penalty", "presence_penalty":
                guard let d = Double(rawValue), d.isFinite else { throw StoryGenerationError.unsupported }
                payload[key] = d
            default: throw StoryGenerationError.unsupported
            }
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard body.count <= 256 * 1024 else { throw StoryGenerationError.budget }
        return .init(id: UUID(), endpoint: config.endpoint, model: config.model, presetName: preset?.summary.name,
                     messages: messages, parameters: parameters, omittedTurns: turns.count - recent.count,
                     session: session, expectedCount: turns.count, action: action, memoryRevision: memoryRevision, body: body)
    }
}

extension LibraryService {
    /// Local only; the presentation uses these same messages and the transport uses the frozen bytes.
    public func prepareStoryGeneration(session: StorySession, expectedCount: Int, action: String,
                                       configuration: StoryModelConfiguration) async throws -> StoryGenerationDraft {
        try Task.checkCancellation()
        let turns = try await store.storyTurns(sessionID: session.id)
        guard expectedCount == turns.count else { throw StoryTurnError.staleCount }
        let preset: StoryPresetVersion?
        if let id = session.presetID { preset = try await store.storyPreset(id: id) } else { preset = nil }
        try await recoverLocalStoryMemory(sessionID: session.id)
        let memory = try await store.storyMemoryContext(sessionID: session.id, action: action, recentStart: max(1, turns.count - 7))
        return try StoryGenerationBuilder.prepare(session: session, turns: turns, preset: preset, action: action, configuration: configuration, memoryText: memory.text, memoryRevision: memory.revision)
    }

    public func generateStoryTurn(_ draft: StoryGenerationDraft, onPartial: @escaping @Sendable (String) async -> Void) async throws -> StoryTurn {
        try await runConfirmedStoryGeneration(draft) { config, bytes in
            try await StoryModelTransport.complete(configuration: config, body: bytes) { cumulative in
                await onPartial(draft.presetName == nil ? StoryMemoryProtocol.visiblePrefix(cumulative) : cumulative)
            }
        }
    }

    // The injectable seam is the network boundary; integration checks use no credentials or network.
    func runConfirmedStoryGeneration(_ draft: StoryGenerationDraft,
        completion: @Sendable (StoryModelConfiguration, Data) async throws -> String) async throws -> StoryTurn {
        let key = draft.session.id
        guard activeStoryGenerations.insert(key).inserted else { throw StoryGenerationError.busy }
        defer { activeStoryGenerations.remove(key) }
        try Task.checkCancellation()
        try await store.checkGenerationDraft(draft)
        try Task.checkCancellation()
        let config = StoryModelConfiguration(endpoint: draft.endpoint, model: draft.model)
        let raw = try await completion(config, draft.body)
        try Task.checkCancellation()
        // A malformed, oversized sidecar must not discard otherwise complete bounded prose.
        guard raw.utf8.count <= StoryModelSSEParser.maxBytes else { throw StoryGenerationError.budget }
        let response: (narration: String, changes: [StoryMemoryFact]?) = draft.presetName == nil
            ? StoryMemoryProtocol.split(raw) : (raw, nil)
        let prose = response.narration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { throw StoryGenerationError.incomplete }
        guard prose.utf8.count <= 128 * 1024 else { throw StoryGenerationError.budget }
        let turn = try await store.commitStoryGeneration(draft, text: prose)
        // Publication is final. A failed/cancelled second transaction leaves the durable job pending.
        if let changes = response.changes {
            do { try await store.applyMemory(sessionID: key, turnID: turn.id, narration: prose, changes: changes) }
            catch { return turn }
        }
        return turn
    }
}
