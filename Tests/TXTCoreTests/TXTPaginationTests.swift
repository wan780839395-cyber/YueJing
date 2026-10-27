import Foundation
import Testing
@testable import TXTCore

struct TXTPaginationTests {
    @Test func nativeCoreTextPagesAdvanceAndCoverEveryUTF16Unit() async throws {
        let source = String(repeating: "中文😀e\u{301}👩‍👩‍👧‍👦，下一句。\r\n", count: 160)
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(contentsOf: source.utf8)
        let processor = TXTProcessor()
        let document = try await processor.decode(bytes, chunkSize: 3)
        var graphemeBoundaries: Set<Int> = [0], cursor = 0
        for character in document.text { cursor += String(character).utf16.count; graphemeBoundaries.insert(cursor) }
        for layout in [TXTPageLayout(width: 240, height: 180), TXTPageLayout(width: 170, height: 160, fontSize: 24, lineSpacing: 7)] {
            let pages = try await processor.paginate(document, layout: layout)
            #expect(pages.count > 1)
            var nextUTF16 = 0, nextByte = 3, text = "", raw = Data()
            for page in pages {
                #expect(page.documentVersion == document.versionID)
                #expect(page.utf16Range.location.value == nextUTF16)
                #expect(page.rawByteRange.location.value == nextByte)
                #expect(page.utf16Range.length > 0 && page.rawByteRange.length > 0)
                #expect(graphemeBoundaries.contains(page.utf16Range.location.value))
                #expect(graphemeBoundaries.contains(page.utf16Range.end.value))
                text += (document.text as NSString).substring(with: page.utf16Range.nsRange)
                raw.append(bytes.subdata(in: page.rawByteRange.location.value..<page.rawByteRange.end.value))
                nextUTF16 = page.utf16Range.end.value; nextByte = page.rawByteRange.end.value
            }
            #expect(nextUTF16 == document.utf16Count)
            #expect(nextByte == bytes.count)
            #expect(Data(text.utf8) == Data(document.text.utf8))
            #expect(raw == Data(bytes.dropFirst(3)))
        }
    }

    @Test func invalidOrUnusableGeometryFailsInsteadOfLooping() async throws {
        let processor = TXTProcessor()
        let document = try await processor.decode(Data("😀中文".utf8), using: .utf8)
        for layout in [TXTPageLayout(width: 0, height: 100), TXTPageLayout(width: .nan, height: 100),
                       TXTPageLayout(width: 100, height: .infinity), TXTPageLayout(width: 100, height: 100, lineSpacing: -1),
                       TXTPageLayout(width: 1, height: 1, fontSize: 18)] {
            #expect(throws: TXTError.self) { try await processor.paginate(document, layout: layout) }
        }
        let empty = try await processor.decode(Data())
        #expect(try await processor.paginate(empty, layout: TXTPageLayout(width: 100, height: 100)).isEmpty)
    }
}
