import Foundation

/// No credential, live connection, or mutable message list in a repair preview.
public struct StoryMemoryRepairDraft: Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let sequence: Int
    public let endpoint: URL
    public let model: String
    public let messages: [StoryModelMessage]
    let turnID: UUID
    let narration: String
    let body: Data
}

extension LibraryService {
    /// Local-only replay of fully understood prose; never guesses from the player's action.
    public func recoverLocalStoryMemory(sessionID: UUID) async throws {
        for turn in try await store.storyMemoryPending(sessionID: sessionID) {
            try Task.checkCancellation()
            if let changes = StoryMemoryProtocol.localProposal(turn.narration) {
                try await store.applyMemory(sessionID: sessionID, turnID: turn.id, narration: turn.narration, changes: changes)
            }
        }
    }

    public func prepareStoryMemoryRepair(sessionID: UUID, turnID: UUID, configuration: StoryModelConfiguration) async throws -> StoryMemoryRepairDraft {
        let jobs = try await store.storyMemoryPending(sessionID: sessionID)
        guard let turn = jobs.first(where: { $0.id == turnID }) else { throw StoryTurnError.staleCount }
        let messages = [StoryModelMessage(role: "system", content: StoryMemoryProtocol.instruction + "\n现在是对已保存回合的补记。只返回候选 JSON 数组，不要分隔符，不要续写、改写或输出正文。只用本幕可证实的事实，不把对白、尝试、假设或传闻当成事实。"), StoryModelMessage(role: "user", content: turn.narration)]
        let payload = try JSONSerialization.data(withJSONObject: ["model":configuration.model, "stream":false, "messages":messages.map { ["role":$0.role, "content":$0.content] }], options: .sortedKeys)
        guard payload.count <= 256 * 1024 else { throw StoryGenerationError.budget }
        return .init(id: UUID(), sessionID:sessionID, sequence:turn.sequence, endpoint: configuration.endpoint, model: configuration.model, messages:messages, turnID:turn.id, narration:turn.narration, body:payload)
    }

    public func repairStoryMemory(_ draft: StoryMemoryRepairDraft) async throws {
        try await runConfirmedMemoryRepair(draft) { config, body in
            try await StoryModelTransport.complete(configuration: config, body: body) { _ in }
        }
    }

    // Same branch lock as generation: parallel taps must never start a second billable call.
    func runConfirmedMemoryRepair(_ draft: StoryMemoryRepairDraft, completion: @Sendable (StoryModelConfiguration, Data) async throws -> String) async throws {
        guard activeStoryGenerations.insert(draft.sessionID).inserted else { throw StoryGenerationError.busy }
        defer { activeStoryGenerations.remove(draft.sessionID) }
        let pending = try await store.storyMemoryPending(sessionID: draft.sessionID)
        guard pending.contains(where: { $0.id == draft.turnID && $0.sequence == draft.sequence && $0.narration.utf8.elementsEqual(draft.narration.utf8) }) else { throw StoryTurnError.staleCount }
        try Task.checkCancellation()
        let reply = try await completion(.init(endpoint: draft.endpoint, model: draft.model), draft.body)
        let changes = try StoryMemoryProtocol.parseChanges(reply, narration: draft.narration)
        try Task.checkCancellation()
        try await store.applyMemory(sessionID:draft.sessionID, turnID:draft.turnID, narration:draft.narration, changes:changes)
    }
}
