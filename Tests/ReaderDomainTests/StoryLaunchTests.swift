import Foundation
import Testing
@testable import ReaderDomain

struct StoryLaunchTests {
    @Test func localStoryStartsFromImportedTextAndEPUBAndRestoresBothRoles() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let txt = f.root.appendingPathComponent("渡口.txt")
        let text = String(repeating: "月", count: 25_000)
        try (Data([0xef,0xbb,0xbf]) + Data(text.utf8)).write(to: txt)
        let a = try await f.install(txt).book
        let b = try await f.install(f.archive()).book
        let before = try await f.store.books()
        await #expect(throws: StoryLaunchError.self) {
            try await f.service.startStory(book: a, roleKind: .canon, roleName: "   ", premise: "")
        }
        let canon = try await f.service.startStory(book: a, roleKind: .canon, roleName: " 青岚 ", premise: "")
        let original = try await f.service.startStory(book: b, roleKind: .original, roleName: "阿渡", premise: "送信人")
        #expect(canon.opening == String(text.prefix(1400)))
        #expect(StoryOpeningText.from(text: "版权页\n第一章 潮声\n来客到了。\n第二章 雾\n后文") == "第一章 潮声\n来客到了。")
        let nav = [EPUBNavigationItem(title: "版权", path: "front"),
                   EPUBNavigationItem(title: "第一章 潮声", path: "body", fragment: "ch1"),
                   EPUBNavigationItem(title: "第二章 雾", path: "body", fragment: "ch2")]
        let packed = EPUBPackage(sourceSHA256: "synthetic", title: "fixture", spine: ["front", "body"],
                                 navigation: nav, resources: [], textNodes: ["front": ["版权页"],
                                    "body": ["前言", "第一章 潮声", "来客到了。", "第二章 雾", "后文"]], coverPath: nil)
        #expect(try StoryOpeningText.from(package: packed) == "第一章 潮声\n来客到了。")
        #expect(canon.roleName == "青岚" && canon.roleKind == .canon && canon.bookID == a.id)
        #expect(original.opening.contains("First chapter") && !original.opening.contains("Second chapter"))
        #expect(original.roleKind == .original && original.premise == "送信人" && original.bookID == b.id)
        #expect(canon.id != original.id)
        let first = try await f.store.playStoryTurn(sessionID: canon.id, expectedCount: 0, action: "我决定先听听动静。")
        #expect(first.sequence == 1 && first.action == "我决定先听听动静。" && !first.narration.isEmpty)
        await #expect(throws: (any Error).self) {
            try await f.store.playStoryTurn(sessionID: canon.id, expectedCount: 0, action: "重复点击")
        }
        let next = try await f.store.playStoryTurn(sessionID: canon.id, expectedCount: 1, action: "我上前询问。")
        #expect(next.sequence == 2 && first.id != next.id && first.narration != next.narration)
        let after = try await f.store.books(); #expect(after == before)
        let fresh = try LibraryStore(root: f.managed)
        let saved = try await fresh.storySessions()
        #expect(saved.count == 2 && saved.contains(canon) && saved.contains(original))
        let restored = try await fresh.storyTurns(sessionID: canon.id)
        let otherBranch = try await fresh.storyTurns(sessionID: original.id)
        #expect(restored == [first, next] && otherBranch.isEmpty)
        let sibling = try await f.service.startStory(book: a, roleKind: .canon, roleName: canon.roleName, premise: "")
        let kept = try await fresh.playStoryTurn(sessionID: sibling.id, expectedCount: 0, action: "驻足片刻")
        try await fresh.deleteStorySession(id: canon.id)
        try await fresh.deleteStorySession(id: canon.id)
        let reopened = try LibraryStore(root: f.managed)
        let remaining = try await reopened.storySessions()
        let keptTurns = try await reopened.storyTurns(sessionID: sibling.id)
        let remainingBooks = try await reopened.books()
        #expect(Set(remaining.map(\.id)) == Set([sibling.id, original.id]))
        #expect(keptTurns == [kept] && remainingBooks == before)
    }
}
