import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct TXTBookSearchTests {
    @Test func crossWindowMatchesMapNormalizedTextToOriginalBytesInEveryEncoding() async throws {
        for encoding in TXTEncoding.allCases {
            let symbol = encoding == .gbk ? "文" : "😀"
            let heading = "第一章 起点"
            // After BOM removal and CRLF folding, the window edge bisects the emoji
            // (or precedes the newline in GBK). The match also crosses into chapter two.
            let prefix = heading + "\r\n" + String(repeating: "中", count: 4094 - heading.utf16.count - 1)
            let original = prefix + "界" + symbol + "\r\n第二章 终点\r\n正文"
            let f = try await DerivedBookFixture(bytes: DerivedBookFixture.bytes(original, encoding: encoding, bom: true), encoding: encoding)
            defer { f.remove() }
            let saved = try await f.savedAnchor()
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            let service = LibraryService(store: f.store)
            let reader = try await service.openReader(id: f.book.id, budget: DerivedBookFixture.limits(read: 4096))
            let query = "界" + symbol + "\n第二章"
            let result = try await reader.searchBook(query)
            #expect(result.hits.count == 1 && !result.hasMore)
            let hit = try #require(result.hits.first)
            let raw = try DerivedBookFixture.bytes(prefix, encoding: encoding, bom: true).count
            let expected = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: raw)
            #expect(hit.location == .txt(expected) && hit.chapterTitle == heading && hit.snippet.contains(query))
            let window = try await reader.prepareSearchWindow(hit, width: 320, preferences: reader.preferences)
            #expect(window.anchor == expected && window.targetUTF16 == 4094)
            try await reader.close()
            #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == saved)
            #expect(await service.readingRouteStatistics().documentDecodes == 0)
        }
    }

    @Test func overlapAndLimitUseGlobalNonOverlappingMatchesAndOneExtraWitness() async throws {
        let text = String(repeating: ".", count: 4093) + String(repeating: "a", count: 202) + String(repeating: "b", count: 200)
        let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        for (query, first, more) in [("aa", 4093, true), ("bb", 4295, false)] {
            let result = try await reader.searchBook(query)
            #expect(result.hits.count == 100 && result.hasMore == more)
            let offsets = result.hits.compactMap { hit -> Int? in
                guard case .txt(let anchor) = hit.location else { return nil }; return anchor.rawByteOffset
            }
            #expect(offsets == (0..<100).map { first + 2 * $0 })
        }
        try await reader.close()
    }

    @Test func oversizedGraphemeIsSkippedWithoutSplittingOrHidingFollowingMatches() async throws {
        let prefix = "e" + String(repeating: "\u{301}", count: 12000)
        let f = try await DerivedBookFixture(bytes: Data((prefix + "Z标记Z").utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: DerivedBookFixture.limits(read: 4096))
        #expect(try await reader.searchBook("e").hits.isEmpty)
        let result = try await reader.searchBook("标记")
        let expected = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: prefix.utf8.count + 1)
        #expect(result.hits.map(\.location) == [.txt(expected)])
        try await reader.close()
    }

    @Test func cancelledSupersededClosedAndInexactSearchPositionsAreRejected() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let result = try await reader.searchBook("😀")
        let hit = try #require(result.hits.first)
        guard case .txt(let good) = hit.location else { Issue.record("Expected a TXT result"); return }
        let interior = good.rawByteOffset + "😀e".utf8.count // combining mark, exact scalar but not grapheme
        for anchor in [ReadingAnchor(bookID: "other", versionID: good.versionID, rawByteOffset: good.rawByteOffset),
                       ReadingAnchor(bookID: good.bookID, versionID: "other", rawByteOffset: good.rawByteOffset),
                       ReadingAnchor(bookID: good.bookID, versionID: good.versionID, rawByteOffset: f.book.byteCount),
                       ReadingAnchor(bookID: good.bookID, versionID: good.versionID, rawByteOffset: interior)] {
            let invalid = BookSearchHit(chapterTitle: "", snippet: "", location: .txt(anchor))
            await #expect(throws: LibraryError.invalidAnchor) {
                try await reader.prepareSearchWindow(invalid, width: 320, preferences: reader.preferences)
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.searchBook("😀")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let next = try await f.service.openReader(id: f.book.id, budget: f.budget)
        await #expect(throws: CancellationError.self) { try await reader.searchBook("😀") }
        await #expect(throws: CancellationError.self) { try await reader.prepareSearchWindow(hit, width: 320, preferences: reader.preferences) }
        try await reader.close(); try await next.close()
        await #expect(throws: DerivedStorageError.closed) { try await reader.searchBook("😀") }
    }
}
