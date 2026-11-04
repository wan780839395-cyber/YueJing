import CryptoKit
import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct LongBookAcceptanceTests {
    @Test func a06FixedTenMiB128ChaptersImportNavigateAndReopen() async throws {
        let bytes = Self.sample()
        #expect(bytes.count == 10 * 1024 * 1024)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(sha == "d7491190dee070c3229bd782fac4ef73a56c55ab8a0d3440f13559af22252cf8")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("A06-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A06.txt"), managed = root.appendingPathComponent("Managed")
        try bytes.write(to: source)
        let store = try LibraryStore(root: managed), budget = try ReaderStoragePolicy.budget()
        let service = LibraryService(store: store)
        let preparation = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: budget)
        guard case .completed(let receipt) = preparation else { Issue.record("UTF8 fixture must import without a choice"); return }
        #expect(receipt.book.id == sha && receipt.book.format == .txt)
        let reader = try await service.openReader(id: receipt.book.id, budget: budget)
        #expect(reader.source.metadata.chapterCount == 128)
        var chapters: [TXTChapter] = []
        for start in stride(from: 0, to: 128, by: 32) {
            chapters += try await reader.chapterPage(start: start, limit: 32)
        }
        #expect(chapters.count == 128)
        for (index, chapter) in chapters.enumerated() {
            #expect(chapter.rawByteRange.location.value == index * 81920)
            #expect(chapter.title == String(format: "第%04d章 合成长书观察", index + 1))
        }
        for chapterIndex in [0, 31, 63, 95, 127] {
            let anchor = ReadingAnchor(bookID: receipt.book.id, versionID: receipt.book.versionID,
                                       rawByteOffset: chapterIndex * 81920)
            let window = try await reader.window(around: anchor, width: 390, preferences: reader.preferences)
            #expect(window.anchor == anchor)
            #expect(window.targetUTF16 == chapters[chapterIndex].utf16Range.location.value)
        }
        let saved = ReadingAnchor(bookID: receipt.book.id, versionID: receipt.book.versionID,
                                  rawByteOffset: 95 * 81920, lineFraction: 0.35)
        try await reader.close(anchor: saved, sequence: 1)
        let freshStore = try LibraryStore(root: managed), fresh = LibraryService(store: freshStore)
        let reopened = try await fresh.openReader(id: receipt.book.id, budget: budget)
        #expect(reopened.reading.anchor == saved && reopened.cacheDisposition == .diskHit)
        #expect(reopened.reading.session.id != reader.reading.session.id)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: await freshStore.fileURL(bookID: receipt.book.id)) == bytes)
        try await reopened.close()
        // Service/store reconstruction is not App process restart, visible first paint, or 10-minute phone acceptance.
    }

    static func sample() -> Data {
        var result = Data(); result.reserveCapacity(10 * 1024 * 1024)
        for chapter in 1...128 {
            var block = Data(String(format: "第%04d章 合成长书观察\n", chapter).utf8)
            let ending = Data(String(format: "\nA06-END-C%04d\n", chapter).utf8)
            var paragraph = 1
            while true {
                let prefix = String(format: "C%04d-P%05d ", chapter, paragraph)
                let line = Data((prefix + "这是专为阅境长书观察生成的虚构测试段落。清晨的步道通向河边，远处的树影随着微风缓缓移动。读者可以用本段编号记录位置，核对跨章、退出和重新打开后的上下文。此处不含私人小说，也没有实际人物资料。\n").utf8)
                if block.count + line.count + ending.count + 1 > 81920 { break }
                block.append(line); paragraph += 1
            }
            block.append(Data(repeating: 0x7E, count: 81920 - block.count - ending.count - 1))
            block.append(0x0A); block.append(ending); result.append(block)
        }
        return result
    }
}
