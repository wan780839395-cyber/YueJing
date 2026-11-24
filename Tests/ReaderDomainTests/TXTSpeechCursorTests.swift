import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct TXTSpeechCursorTests {
    @Test func speechWindowsPreserveEveryUnitAndOriginalAnchorAcrossChaptersAndEncodings() async throws {
        for encoding in TXTEncoding.allCases {
            let prefix = "第一章 起点\r\n略过。"
            let suffix = String(repeating: "文", count: 255) + (encoding == .gbk ? "字" : "😀")
                + "！\r\n第二章 终点\r\n" + String(repeating: "句。", count: 150) + "尾"
            let bytes = try DerivedBookFixture.bytes(prefix + suffix, encoding: encoding, bom: true)
            let f = try await DerivedBookFixture(bytes: bytes, encoding: encoding); defer { f.remove() }
            let saved = try await f.savedAnchor()
            let reader = try await f.service.openReader(id: f.book.id, budget: DerivedBookFixture.limits(read: 256))
            let start = try DerivedBookFixture.bytes(prefix, encoding: encoding, bom: true).count
            let origin = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: start)
            let cursor = TXTSpeechCursor(source: reader.source, origin: origin)
            var joined = "", offset = prefix.replacingOccurrences(of: "\r\n", with: "\n").utf16.count
            while let part = try await cursor.next() {
                let units = part.text.utf16.count
                try #require((1...256).contains(units))
                let expected = try f.document.offsets.rawByteOffset(for: UTF16Offset(offset))
                #expect(part.anchor == ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: expected.value))
                joined += part.text; offset += units
            }
            #expect(joined.utf16.elementsEqual(suffix.replacingOccurrences(of: "\r\n", with: "\n").utf16))
            #expect(try await cursor.next() == nil)
            try await reader.close()
            #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == saved)
        }
    }

    @Test func narrationKeepsDecimalsAndClosingQuotesAndPrefersClauseBoundaries() throws {
        let dialogue = "她问：“真是 3.14 吗？！”下一句。"[...]
        let end = try #require(NarrationPhrase.end(in: dialogue, limit: 256))
        #expect(dialogue[..<end] == "她问：“真是 3.14 吗？！”")
        let clause = "甲乙丙丁，戊己庚辛壬。"[...]
        let split = try #require(NarrationPhrase.end(in: clause, limit: 8))
        #expect(clause[..<split] == "甲乙丙丁，")
        #expect(clause[split...] == "戊己庚辛壬。")
    }

    @Test func nextNarrationSentenceIsNotCutAtPreviousStorageWindow() async throws {
        let first = String(repeating: "甲", count: 249) + "。"
        let second = "她说：“这瓶水只要 3.14 元。”"
        let f = try await DerivedBookFixture(bytes: Data((first + second + "尾").utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: DerivedBookFixture.limits(read: 256))
        let cursor = TXTSpeechCursor(source: reader.source, origin: ReadingAnchor(bookID: f.book.id,
            versionID: f.book.versionID, rawByteOffset: 0))
        let a = try #require(try await cursor.next()), b = try #require(try await cursor.next())
        #expect(a.text == first && b.text == second && b.anchor.rawByteOffset == first.utf8.count)
        try await reader.close()
    }

    @Test func oversizedGraphemeAndCancellationNeverSkipOrRepeatSpeechScalars() async throws {
        // The first 256-unit probe lands inside a supplementary combining mark.
        let text = "e" + String(repeating: "\u{1D165}", count: 500) + "。尾"
        let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: DerivedBookFixture.limits(read: 256))
        let origin = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 0)
        let cursor = TXTSpeechCursor(source: reader.source, origin: origin)
        let first = try #require(try await cursor.next())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cursor.next()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        var joined = first.text
        while let next = try await cursor.next() {
            try #require((1...256).contains(next.text.utf16.count))
            #expect(next.anchor.rawByteOffset == joined.utf8.count)
            joined += next.text
        }
        #expect(joined.utf8.elementsEqual(text.utf8))
        try await reader.close()
    }
}
