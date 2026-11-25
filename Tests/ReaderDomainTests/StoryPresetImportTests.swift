import Foundation
import Testing
@testable import ReaderDomain

struct StoryPresetImportTests {
    @Test func localPresetImportChecksOrderAndPinsImmutableStoryVersion() async throws {
        try checkStoryPresetParser()
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("sample.json")
        let json = #"{"name":"test","prompts":[{"identifier":"B","name":"Tone","role":"system","content":"Quiet prose.","system_prompt":false},{"identifier":"chatHistory","name":"Chat History","marker":true,"system_prompt":true}],"prompt_order":[{"character_id":100001,"order":[{"identifier":"B","enabled":true},{"identifier":"chatHistory","enabled":true}]}]}"#
        let original = Data(json.utf8); try original.write(to: url)
        let first = try await f.service.importStoryPreset(from: url)
        let duplicate = try await f.service.importStoryPreset(from: url)
        #expect(first.summary.id == duplicate.summary.id && first.summary.canSelect)
        #expect(try Data(contentsOf: url) == original)
        let book = try await f.install(f.archive()).book
        let session = try await f.service.startStory(book: book, roleKind: .original, roleName: "书客", premise: "", presetID: first.summary.id)
        try Data(json.replacingOccurrences(of: "Quiet prose.", with: "Short lines.").utf8).write(to: url)
        let newer = try await f.service.importStoryPreset(from: url)
        #expect(first.summary.id != newer.summary.id)
        try Data(json.replacingOccurrences(of: "Quiet prose.", with: "{{unknown_macro}}").utf8).write(to: url)
        let blocked = try await f.service.importStoryPreset(from: url)
        #expect(!blocked.summary.canSelect && !blocked.issues.isEmpty)
        await #expect(throws: StoryPresetStorageError.self) {
            try await f.service.startStory(book: book, roleKind: .canon, roleName: "书客", premise: "", presetID: blocked.summary.id)
        }
        let fresh = try LibraryStore(root: f.managed)
        let sessions = try await fresh.storySessions()
        #expect(sessions.count == 1 && sessions[0].id == session.id && sessions[0].presetID == first.summary.id)
        let kept = try await fresh.storyPreset(id: first.summary.id)
        #expect(kept == first)
        let all = try await fresh.storyPresets()
        #expect(all.count == 3)
    }
}
