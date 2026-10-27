import Foundation
import Testing
@testable import TXTCore

struct TXTChapterTests {
    @Test func wholeLineHeadingsPreservePreambleAndOriginalBytes() async throws {
        let source = "说明😀\r\n\r\n第一章 开始\r\n正文e\u{301}。\r\n他说：第二章 到来\r\n第二章介绍了背景\r\n第3章 这是一段叙述。\r\n\r\n第二章：结束\r\n尾段\r"
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(contentsOf: source.utf8)
        let processor = TXTProcessor()
        let document = try await processor.decode(bytes, chunkSize: 1)
        let chapters = try await processor.chapters(in: document)
        #expect(chapters.map(\.title) == [nil, "第一章 开始", "第二章：结束"])
        let first = try #require(bytes.range(of: Data("第一章 开始".utf8)))
        let second = try #require(bytes.range(of: Data("第二章：结束".utf8)))
        #expect(chapters[0].rawByteRange.location == RawByteOffset(3))
        #expect(chapters[1].rawByteRange.location == RawByteOffset(first.lowerBound))
        #expect(chapters[2].rawByteRange.location == RawByteOffset(second.lowerBound))
        var restoredBytes = Data(), restoredText = "", expected = 0
        for chapter in chapters {
            #expect(chapter.utf16Range.location.value == expected)
            #expect(chapter.utf16Range.length > 0)
            #expect(chapter.documentVersion == document.versionID)
            #expect(chapter.id == "\(document.versionID):\(chapter.rawByteRange.location.value)")
            expected = chapter.utf16Range.end.value
            restoredText += (document.text as NSString).substring(with: chapter.utf16Range.nsRange)
            restoredBytes.append(bytes.subdata(in: chapter.rawByteRange.location.value..<chapter.rawByteRange.end.value))
        }
        #expect(expected == document.utf16Count)
        #expect(Data(restoredText.utf8) == Data(document.text.utf8))
        #expect(restoredBytes == Data(bytes.dropFirst(3)))
    }

    @Test func proseAndLongLinesAreNotSilentlyTurnedIntoHeadings() async throws {
        let source = "这是第1章 标题\n第一章介绍了故事\n第2章 一段叙述。\nChapter 4 is ordinary prose.\n第5章 标题\u{2028}不是同一行\n第3章 " + String(repeating: "字", count: 81) + "\n"
        let processor = TXTProcessor()
        let document = try await processor.decode(Data(source.utf8), using: .utf8)
        let chapters = try await processor.chapters(in: document)
        #expect(chapters.count == 1)
        #expect(chapters.first?.title == nil)
        #expect(chapters.first?.utf16Range.length == document.utf16Count)
    }

    @Test func consecutiveAndTerminalHeadingsHaveNoEmptyPhantomSection() async throws {
        let processor = TXTProcessor()
        let document = try await processor.decode(Data("第1章 开始\n第2章 结束".utf8), using: .utf8)
        let chapters = try await processor.chapters(in: document)
        #expect(chapters.count == 2)
        #expect(chapters.allSatisfy { $0.utf16Range.length > 0 })
        #expect(chapters.last?.utf16Range.end.value == document.utf16Count)
        let empty = try await processor.decode(Data())
        #expect(try await processor.chapters(in: empty).isEmpty)
    }
}
