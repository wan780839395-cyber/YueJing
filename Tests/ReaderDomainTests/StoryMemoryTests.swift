import Foundation
import Testing
@testable import ReaderDomain

struct StoryMemoryTests {
    @Test func committedMemoryRecoversWithoutRewritingAndReachesNextRequest() async throws {
        try checkStoryMemoryProtocol()
        try measureNarrativeCorpus()
        try checkStoryCandidateChecks()
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let book = try await f.install(f.archive()).book
        let a = try await f.service.startStory(book:book, roleKind:.original, roleName:"我", premise:"")
        let b = try await f.service.startStory(book:book, roleKind:.original, roleName:"我", premise:"")
        let cfg = StoryModelConfiguration(endpoint: URL(string:"https://fixture.invalid/v1/chat/completions")!, model:"fixture")
        let m = StoryMemoryProtocol.marker
        func encoded(_ value:String, _ evidence:String) throws -> String {
            let fact = StoryMemoryFact(kind:"possession",subject:"钥匙",value:value,evidence:evidence)
            return String(decoding:try JSONEncoder().encode([fact]),as:UTF8.self)
        }
        func round(_ s:LibraryService, _ branch:StorySession, _ count:Int, _ response:String) async throws -> StoryTurn {
            let draft = try await s.prepareStoryGeneration(session:branch, expectedCount:count, action:"我去开门", configuration:cfg)
            return try await s.runConfirmedStoryGeneration(draft) { _,_ in response }
        }
        let start = "我拿着钥匙。"
        for branch in [a,b] { _ = try await round(f.service,branch,0,start + m + encoded("我",start)) }
        let accepted = "阿宁接过钥匙。"
        let turn = try await round(f.service,a,1,"风过长廊。" + accepted + m + "{broken")
        #expect(turn.narration == "风过长廊。" + accepted)
        _ = try await round(f.service,b,1,"阿宁摇头，没有接。" + m + "[]")
        for i in 2..<12 { for branch in [a,b] { _ = try await round(f.service,branch,i,"雨打在石阶上。" + m + "[]") } }
        let service = LibraryService(store:try LibraryStore(root:f.managed))
        let pending = try await service.store.storyMemoryPending(sessionID:a.id)
        #expect(pending.map(\.id) == [turn.id])
        let stale = try await service.prepareStoryGeneration(session:a, expectedCount:12, action:"推开门", configuration:cfg)
        #expect(stale.messages.contains { $0.content.contains(turn.narration) && $0.content.contains("缺口") })
        let repair = try await service.prepareStoryMemoryRepair(sessionID:a.id, turnID:turn.id, configuration:cfg)
        #expect(repair.messages.last?.content == turn.narration)
        await #expect(throws: (any Error).self) { try await service.runConfirmedMemoryRepair(repair) { _,_ in "not JSON" } }
        await #expect(throws: CancellationError.self) { try await service.runConfirmedMemoryRepair(repair) { _,_ in throw CancellationError() } }
        let afterFailure = try await service.store.storyMemoryPending(sessionID:a.id)
        #expect(afterFailure == pending)
        let reply = try encoded("阿宁",accepted)
        try await service.runConfirmedMemoryRepair(repair) { _,bytes in
            let decoded = try JSONSerialization.jsonObject(with: bytes)
            let data = try #require(decoded as? [String:Any]); let sent = try #require(data["messages"] as? [[String:String]])
            let preview = repair.messages.map { ["role":$0.role, "content":$0.content] }
            #expect(sent == preview); return reply
        }
        await #expect(throws: StoryTurnError.self) { try await service.runConfirmedMemoryRepair(repair) { _,_ in Issue.record("Duplicate repair reached transport"); return reply } }
        await #expect(throws: StoryTurnError.self) { try await service.runConfirmedStoryGeneration(stale) { _,_ in Issue.record("Stale memory preview sent"); return "unexpected" } }
        let after = try await service.store.storyTurns(sessionID:a.id)
        #expect(after.count == 12 && after[1] == turn)
        for (branch, expected) in [(a,"阿宁"),(b,"我")] {
            let next = try await service.prepareStoryGeneration(session:branch, expectedCount:12, action:"我推了推门", configuration:cfg)
            let expectedLine = "possession · 钥匙：" + expected
            let actual = try await service.runConfirmedStoryGeneration(next) { _,bytes in
                let decoded = try JSONSerialization.jsonObject(with: bytes)
                let data = try #require(decoded as? [String:Any]); let sent = try #require(data["messages"] as? [[String:String]])
                let preview = next.messages.map { ["role":$0.role, "content":$0.content] }; #expect(sent == preview)
                let block = sent.first { $0["content"]?.hasPrefix("本局已整理的现状") == true }; let context = try #require(block?["content"])
                #expect(context.contains(expectedLine)); #expect(!context.contains("尚有记忆缺口")); #expect(sent.last?["content"] == "我推了推门"); return "门响了一声。" + m + "[]"
            }
            #expect(actual.sequence == 13)
        }
        let returned = "阿宁把钥匙还给我。"
        _ = try await round(service,a,13,returned) // plain response: recover from this proven sentence locally
        let fresh = LibraryService(store:try LibraryStore(root:f.managed))
        let last = try await fresh.prepareStoryGeneration(session:a, expectedCount:14, action:"她还记得钥匙吗", configuration:cfg)
        let context = try #require(last.messages.first { $0.content.hasPrefix("本局已整理的现状") }?.content)
        #expect(context.contains("第14回合 · possession · 钥匙：我")); #expect(context.contains(accepted)); #expect(!context.contains("尚有记忆缺口"))
        let jobs = try await fresh.store.storyMemoryPending(sessionID:a.id); #expect(jobs.isEmpty)
        let promise = StoryMemoryFact(kind:"promise",subject:"我｜阿宁｜明日｜南门｜会面",value:"已约定",evidence:"我答应阿宁明日在南门会面。")
        let secret = StoryMemoryFact(kind:"knowledge",subject:"小青｜账本｜在｜桌上",value:"已知",evidence:"小青知道账本在桌上。")
        let ledger = [promise, secret]
        let encodedLedger = String(decoding:try JSONEncoder().encode(ledger),as:UTF8.self)
        _ = try await round(fresh,a,14,ledger.map(\.evidence).joined() + m + encodedLedger)
        let briefDraft = try await fresh.prepareStoryGeneration(session:a, expectedCount:15, action:"问掌柜昨夜的客人", configuration:cfg)
        let brief = briefDraft.sceneBrief
        #expect(brief.sessionID == a.id && brief.bookVersion == book.versionID)
        let privateRows = brief.entries.filter { $0.layer == .characterKnowledge }
        #expect(privateRows.count == 1 && privateRows.first?.holder == "小青" && privateRows.first?.sequence == 15)
        #expect(brief.entries.filter { $0.layer == .canonOpening }.map(\.text) == [a.opening])
        #expect(brief.entries.contains { $0.layer == .branchState && $0.sequence == 15 && $0.text.contains("已约定") })
        #expect(!brief.entries.contains { $0.layer == .branchState && $0.text.contains("小青知道") })
        for entry in brief.entries { #expect(!entry.reason.isEmpty && briefDraft.messages.contains { $0.content.contains(entry.text) }) }
        let otherBrief = try await fresh.prepareStoryGeneration(session:b, expectedCount:13, action:"问掌柜昨夜的客人", configuration:cfg)
        #expect(!otherBrief.sceneBrief.entries.contains { $0.layer == .characterKnowledge || $0.text.contains(promise.evidence) })
    }
}
