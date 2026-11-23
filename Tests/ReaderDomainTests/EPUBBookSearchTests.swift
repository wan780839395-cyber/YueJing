import Foundation
import Testing
@testable import ReaderDomain

struct EPUBBookSearchTests {
    @Test func searchReportsBothChaptersAndDoesNotMoveSavedPosition() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive())
        let reader = try await f.service.openEPUB(id: receipt.book.id)
        let saved = try EPUBLibraryFixture.position(reader, offset: 1)
        let token = try await reader.beginNavigation(path: saved.path)
        #expect(try await reader.markReady(token))
        #expect(try await reader.save(saved, sequence: 1, token: token))
        let page = try await reader.searchBook("  tail  ")
        #expect(!page.hasMore && page.hits.count == 2)
        #expect(page.hits.map(\.chapterTitle) == ["First", "Second"])
        for (i, hit) in page.hits.enumerated() {
            let pos = try await reader.resolveSearchHit(hit)
            #expect(pos.path == reader.publication.package.spine[i] && pos.utf16Offset == 6)
            #expect(hit.snippet.contains("tail"))
        }
        let hit = try #require(page.hits.first)
        let noMatches = try await reader.searchBook("not in the fixture")
        #expect(noMatches.hits.isEmpty && !noMatches.hasMore)
        try await reader.abandon()
        await #expect(throws: EPUBError.staleSession) { try await reader.resolveSearchHit(hit) }
        let next = try await f.service.openEPUB(id: receipt.book.id)
        #expect(next.reading.position == saved)
        try await next.abandon()
    }

    @Test func literalSearchRespectsUTF16GraphemesAndLimits() throws {
        let samples = try BookSearchMatcher.matches(in: "甲😀乙乙e\u{301}.*", query: "乙", limit: 8)
        #expect(samples.map(\.offset) == [3, 4])
        #expect(try BookSearchMatcher.matches(in: "e\u{301}", query: "e", limit: 1).isEmpty)
        #expect(try BookSearchMatcher.matches(in: "a.*b", query: ".*", limit: 1).first?.offset == 1)
        #expect(try BookSearchMatcher.matches(in: String(repeating: "甲", count: 102), query: "甲", limit: 100).count == 100)
        #expect(throws: BookSearchMatcher.QueryError.self) { try BookSearchMatcher.query(" \n") }
        #expect(throws: BookSearchMatcher.QueryError.self) { try BookSearchMatcher.query(String(repeating: "😀", count: 65)) }
    }
}
