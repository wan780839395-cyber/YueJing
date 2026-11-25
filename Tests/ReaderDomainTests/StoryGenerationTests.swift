import Foundation
import Testing
@testable import ReaderDomain

struct StoryGenerationTests {
    @Test func lockedPresetDrivesConfirmedPayloadAndOnlyCompletedModelTurnPersists() async throws {
        try await checkStoryModelTransport()
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let raw = #"{"temperature":0.5,"openai_max_tokens":480,"prompts":[{"identifier":"A","role":"system","content":"excluded"},{"identifier":"B","role":"user","content":" keep spaces "},{"identifier":"C","role":"system","content":"Write a novel."},{"identifier":"chatHistory","marker":true,"system_prompt":true}],"prompt_order":[{"character_id":100001,"order":[{"identifier":"C","enabled":true},{"identifier":"A","enabled":false},{"identifier":"chatHistory","enabled":true},{"identifier":"B","enabled":true}]}]}"#
        let file = f.root.appendingPathComponent("fixture.json"); try Data(raw.utf8).write(to: file)
        let preset = try await f.service.importStoryPreset(from: file)
        let book = try await f.install(f.archive()).book
        let session = try await f.service.startStory(book: book, roleKind: .original, roleName: "渡客", premise: "送信", presetID: preset.summary.id)
        let config = StoryModelConfiguration(endpoint: URL(string:"https://example.invalid/v1/chat/completions")!, model:"fixture")
        let one = try await f.service.prepareStoryGeneration(session: session, expectedCount: 0, action: "听潮", configuration: config)
        #expect(one.messages.map(\.role) == ["system","user","user","user"])
        #expect(one.messages.first?.content == "Write a novel." && one.messages.last?.content == " keep spaces ")
        #expect(!one.messages.contains { $0.content == "excluded" })
        #expect(one.messages[1].content.contains(session.opening) && one.messages[1].content.contains(session.roleName))
        let bookTurn = try await f.service.runConfirmedStoryGeneration(one) { target, body in
            let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(target.endpoint == one.endpoint && payload["model"] as? String == one.model)
            #expect(payload["temperature"] as? Double == 0.5 && payload["max_tokens"] as? Int == 480)
            let sent = try JSONDecoder().decode([String: [StoryModelMessage]].self, from: JSONSerialization.data(withJSONObject: ["messages":payload["messages"]!]))
            #expect(sent["messages"] == one.messages)
            return "船终于靠岸。"
        }
        #expect(bookTurn.modelName == "fixture")
        await #expect(throws: StoryTurnError.self) {
            try await f.service.runConfirmedStoryGeneration(one) { _,_ in Issue.record("Stale draft reached transport"); return "unexpected" }
        }
        let next = try await f.service.prepareStoryGeneration(session: session, expectedCount: 1, action: "下船", configuration: config)
        #expect(next.messages.filter { $0.role == "assistant" && $0.content == bookTurn.narration }.count == 1)
        await #expect(throws: CancellationError.self) {
            try await f.service.runConfirmedStoryGeneration(next) { _,_ in throw CancellationError() }
        }
        await #expect(throws: StoryGenerationError.self) {
            try await f.service.runConfirmedStoryGeneration(next) { _,_ in return " \n" }
        }
        let reopened = try LibraryStore(root: f.managed)
        #expect(try await reopened.storyTurns(sessionID: session.id) == [bookTurn])
    }
}
