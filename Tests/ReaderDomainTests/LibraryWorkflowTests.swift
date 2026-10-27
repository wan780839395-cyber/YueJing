import CoreText
import Foundation
import GRDB
import Testing
import TXTCore
@testable import ReaderDomain

struct LibraryWorkflowTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func install(_ bytes: Data, store: LibraryStore, ticket: UUID = UUID()) async throws -> LibraryBook {
        let document = try await TXTProcessor().decode(bytes, using: .utf8)
        let book = LibraryBook(id: document.documentID, title: "合成测试", encodingRaw: document.encoding.rawValue,
                               versionID: document.versionID, byteCount: bytes.count, utf16Count: document.utf16Count)
        try await store.beginImport(ticket)
        try bytes.write(to: await store.stagingURL(ticket: ticket))
        return try await store.commitImport(ticket: ticket, proposed: book).book
    }

    @Test func cancelBeforeCommitAndCancelAfterCommitHaveDistinctTruth() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let data = Data("abcdefghij\n".utf8)
        let document = try await TXTProcessor().decode(data, using: .utf8)
        let proposed = LibraryBook(id: document.documentID, title: "取消测试", encodingRaw: document.encoding.rawValue,
                                   versionID: document.versionID, byteCount: data.count, utf16Count: document.utf16Count)
        let cancelled = UUID()
        try await store.beginImport(cancelled)
        try data.write(to: await store.stagingURL(ticket: cancelled))
        _ = await store.cancelImport(cancelled)
        await #expect(throws: CancellationError.self) { try await store.commitImport(ticket: cancelled, proposed: proposed) }
        #expect(try await store.books().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try await store.fileURL(bookID: proposed.id).path))
        let committed = UUID()
        let book = try await install(data, store: store, ticket: committed)
        switch await store.cancelImport(committed) {
        case .alreadyCommitted(let receipt): #expect(receipt.book.id == book.id)
        case .cancelled: Issue.record("A committed import was falsely reported as cancelled")
        }
        #expect(try await store.books().count == 1)
    }

    @Test func schemaMigrationPreservesBooksAndAddsValidatedSettings() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path)
        try LibrarySchema.migrator().migrate(queue, upTo: "v1-books")
        let id = String(repeating: "a", count: 64)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO books(id,title,encodingRaw,versionID,byteCount,utf16Count,addedAt) VALUES (?, '迁移测试', 'UTF-8', 'version', 10, 10, 0)", arguments: [id])
        }
        let store = try LibraryStore(root: root)
        #expect(try await store.books().first?.id == id)
        #expect(try await store.preferences() == ReaderPreferences())
        var preferences = ReaderPreferences(fontSize: 30, lineSpacing: 12, theme: .dark)
        preferences.fontSize = .infinity
        try await store.savePreferences(preferences)
        let reloaded = try LibraryStore(root: root)
        #expect(try await reloaded.preferences() == ReaderPreferences(fontSize: 20, lineSpacing: 12, theme: .dark))
        #expect(try await reloaded.books().first?.id == id)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO progress(bookID,versionID,unit,rawByteOffset,lineFraction,sessionID,sequence) VALUES (?, 'old-version', 'utf16', 5, 0, 'old-session', 1)", arguments: [id])
        }
        let incompatible = try await reloaded.beginReading(bookID: id, versionID: "version")
        #expect(incompatible.anchor == nil)
        #expect(incompatible.ignoredIncompatibleProgress)
    }

    @Test func sessionSequenceAndVersionGuardRejectLateOrMismatchedWrites() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try await install(Data("abcdefghijklmnop\n".utf8), store: store)
        let first = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        let a = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: 6)
        let older = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: 2)
        #expect(try await store.saveProgress(session: first.session, anchor: a, sequence: 2))
        #expect(try await store.saveProgress(session: first.session, anchor: older, sequence: 1) == false)
        let second = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        #expect(second.anchor == a)
        #expect(try await store.saveProgress(session: first.session, anchor: older, sequence: 999) == false)
        let wrong = ReadingAnchor(bookID: book.id, versionID: "another-version", rawByteOffset: 3)
        await #expect(throws: LibraryError.self) { try await store.saveProgress(session: second.session, anchor: wrong, sequence: 3) }
        let third = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        #expect(third.anchor == a)
    }

    @Test func failedFinalSaveStillClosesOldAuthorityWithoutClosingNewSession() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try await install(Data("abcdefghijklmnop\n".utf8), store: store)
        let first = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        let reliable = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: 4)
        #expect(try await store.saveProgress(session: first.session, anchor: reliable, sequence: 1))
        let invalid = ReadingAnchor(bookID: book.id, versionID: "wrong-version", rawByteOffset: 8)
        await #expect(throws: LibraryError.self) { try await store.finishReading(session: first.session, anchor: invalid, sequence: 2) }
        #expect(try await store.saveProgress(session: first.session, anchor: reliable, sequence: 999) == false)
        let newer = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        #expect(newer.anchor == reliable)
        try await store.finishReading(session: first.session, anchor: nil, sequence: 1000)
        let moved = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: 9)
        #expect(try await store.saveProgress(session: newer.session, anchor: moved, sequence: 1))
        let reopened = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        #expect(reopened.anchor == moved)
    }

    @Test func ambiguityPreviewsUseTheSameLateSegmentAndCancellationLeavesNoBook() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Managed")), service = LibraryService(store: store)
        let source = root.appendingPathComponent("合成.txt")
        var bytes = Data(String(repeating: "A", count: 300).utf8); bytes.append(contentsOf: [0xC2, 0xA1])
        try bytes.write(to: source)
        let first = UUID()
        guard case .choose(let choice) = try await service.prepareImport(url: source, ticket: first) else { Issue.record("Expected encoding choice"); return }
        #expect(choice.cards.contains { $0.encoding == .utf8 && $0.text.contains("¡") })
        #expect(choice.cards.contains { $0.encoding == .gbk && $0.text.contains("隆") })
        #expect(try await store.books().isEmpty)
        _ = await service.cancelImport(first)
        await #expect(throws: CancellationError.self) { try await service.confirmImport(ticket: first, encoding: .gbk) }
        #expect(try await store.books().isEmpty)
        let second = UUID()
        guard case .choose = try await service.prepareImport(url: source, ticket: second) else { Issue.record("Expected encoding choice"); return }
        let receipt = try await service.confirmImport(ticket: second, encoding: .gbk)
        #expect(receipt.book.encoding == .gbk)
        let opened = try await service.openBook(id: receipt.book.id)
        #expect(opened.document.text.hasSuffix("隆"))
        #expect(opened.document.versionID == receipt.book.versionID)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func emptyDamagedAndPrecancelledImportsDoNotCreateShelfRows() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Managed")), service = LibraryService(store: store)
        let source = root.appendingPathComponent("输入.txt")
        try Data().write(to: source)
        await #expect(throws: LibraryError.self) { try await service.prepareImport(url: source, ticket: UUID()) }
        let damaged = Data([0xFF]); try damaged.write(to: source)
        await #expect(throws: TXTError.self) { try await service.prepareImport(url: source, ticket: UUID()) }
        let cancelled = UUID(); _ = await service.cancelImport(cancelled)
        await #expect(throws: CancellationError.self) { try await service.prepareImport(url: source, ticket: cancelled) }
        #expect(try await store.books().isEmpty)
        #expect(try Data(contentsOf: source) == damaged)
        let folder = root.appendingPathComponent("目录.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        await #expect(throws: LibraryError.self) { try await service.prepareImport(url: folder, ticket: UUID()) }
        let target = root.appendingPathComponent("链接目标.txt"), link = root.appendingPathComponent("链接.txt")
        let readable = Data("plain text\n".utf8); try readable.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await #expect(throws: LibraryError.self) { try await service.prepareImport(url: link, ticket: UUID()) }
        #expect(try await store.books().isEmpty)
        #expect(try Data(contentsOf: target) == readable)
    }

    @Test func duplicateRepairsMissingCopyAndKeepsEncodingVersionAndProgress() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Managed")), service = LibraryService(store: store)
        let source = root.appendingPathComponent("原文.txt"), bytes = Data("abcdefghijklmnop\n".utf8)
        try bytes.write(to: source)
        guard case .completed(let imported) = try await service.prepareImport(url: source, ticket: UUID()) else { Issue.record("Expected import"); return }
        let book = imported.book
        let opened = try await service.openBook(id: book.id)
        let anchor = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: 7)
        try await store.finishReading(session: opened.reading.session, anchor: anchor, sequence: 1)
        let managed = try await store.fileURL(bookID: book.id)
        try FileManager.default.removeItem(at: managed)
        await #expect(throws: LibraryError.self) { try await service.openBook(id: book.id) }
        guard case .completed(let duplicate) = try await service.prepareImport(url: source, ticket: UUID()) else { Issue.record("Expected duplicate"); return }
        #expect(duplicate.duplicate)
        #expect(duplicate.book.encodingRaw == book.encodingRaw)
        #expect(duplicate.book.versionID == book.versionID)
        let repaired = try await service.openBook(id: book.id)
        #expect(repaired.reading.anchor == anchor)
        try Data("changed content".utf8).write(to: managed)
        await #expect(throws: LibraryError.self) { try await service.openBook(id: book.id) }
        #expect(try await store.books().count == 1)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func fontSpacingAndWidthChangesKeepTheSameVersionedRawAnchor() async throws {
        let bytes = Data(String(repeating: "山河😀e\u{301}，阅读正文。\r\n", count: 600).utf8)
        let document = try await TXTProcessor().decode(bytes, using: .utf8)
        let offset = Data(String(repeating: "山河😀e\u{301}，阅读正文。\r\n", count: 300).utf8).count
        let anchor = ReadingAnchor(bookID: document.documentID, versionID: document.versionID, rawByteOffset: offset, lineFraction: 0.4)
        let engine = ReadingLayoutEngine(bookID: document.documentID, document: document)
        var actualMetrics: [(height: Double, length: Int)] = []
        for (width, style) in [(320.0, ReaderPreferences(fontSize: 16, lineSpacing: 3)), (320, ReaderPreferences(fontSize: 30, lineSpacing: 12)), (700, ReaderPreferences(fontSize: 30, lineSpacing: 12))] {
            let window = try await engine.window(around: anchor, width: width, preferences: style)
            #expect(window.anchor == anchor)
            #expect(window.slices.count <= 7)
            #expect(window.slices.allSatisfy { $0.range.length <= 1024 })
            #expect(window.slices.contains { $0.range.location.value <= window.targetUTF16 && window.targetUTF16 <= $0.range.end.value })
            #expect(try document.offsets.rawByteOffset(for: UTF16Offset(window.targetUTF16)).value == offset)
            let line = try #require(window.slices.flatMap(\.lines).first {
                $0.range.location.value <= window.targetUTF16 && window.targetUTF16 < $0.range.end.value
            })
            let expectedText = (document.text as NSString).substring(with: line.range.nsRange)
            #expect(Data(line.text.utf8) == Data(expectedText.utf8))
            #expect(try document.offsets.rawByteOffset(for: line.range.location).value == line.rawByteStart)
            actualMetrics.append((line.height, line.range.length))
            let source = document.text as NSString
            var cursor = try #require(window.slices.first).range.location.value
            for slice in window.slices {
                #expect(slice.range.location.value == cursor)
                #expect(Data(slice.lines.map(\.text).joined().utf8) == Data(source.substring(with: slice.range.nsRange).utf8))
                var lineEnd = slice.range.location.value
                for line in slice.lines { #expect(line.range.location.value == lineEnd); lineEnd = line.range.end.value }
                #expect(lineEnd == slice.range.end.value)
                cursor = slice.range.end.value
            }
            let first = try #require(window.slices.first), second = try #require(window.slices.dropFirst().first)
            let lastLine = try #require(first.lines.last)
            let combined = source.substring(with: NSRange(location: first.range.location.value,
                                                          length: second.range.end.value - first.range.location.value))
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(style.fontSize), nil)
            let attributed = NSAttributedString(string: combined, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
            let naturalCount = CTTypesetterSuggestLineBreak(typesetter, lastLine.range.location.value - first.range.location.value, width)
            let proposedEnd = lastLine.range.location.value + naturalCount
            let naturalEnd = proposedEnd == source.length ? proposedEnd : source.rangeOfComposedCharacterSequence(at: proposedEnd).location
            #expect(first.range.end.value == naturalEnd)
        }
        #expect(actualMetrics[0].height != actualMetrics[1].height || actualMetrics[0].length != actualMetrics[1].length)
    }
}
