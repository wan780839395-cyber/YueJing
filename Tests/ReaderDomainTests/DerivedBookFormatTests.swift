import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct DerivedBookFormatTests {
    private func checkMappings(_ source: DerivedBookSource, document: TXTDocument) async throws {
        for raw in 0...document.originalBytes.count {
            if let expected = try? document.offsets.utf16Offset(for: RawByteOffset(raw)) {
                #expect(try await source.utf16Offset(for: RawByteOffset(raw)) == expected)
            } else {
                await #expect(throws: TXTError.invalidByteBoundary(RawByteOffset(raw))) { try await source.utf16Offset(for: RawByteOffset(raw)) }
            }
        }
        for utf16 in 0...document.utf16Count {
            if let expected = try? document.offsets.rawByteOffset(for: UTF16Offset(utf16)) {
                #expect(try await source.rawByteOffset(for: UTF16Offset(utf16)) == expected)
            } else {
                await #expect(throws: TXTError.invalidUTF16Boundary(UTF16Offset(utf16))) { try await source.rawByteOffset(for: UTF16Offset(utf16)) }
            }
        }
    }
    @Test func fiveStrictEncodingsRoundTripCoordinatesBOMNewlinesAndPagedChapters() async throws {
        for encoding in TXTEncoding.allCases {
            let text = encoding == .gbk ? "前言\r\n第一章 起点\r\n中文\r第二章 终点\r\n" : "前言\r\n第一章 起点\r\n中😀e\u{301}\r第二章 终点\r\n"
            let f = try await DerivedBookFixture(bytes: DerivedBookFixture.bytes(text, encoding: encoding, bom: true), encoding: encoding)
            defer { f.remove() }
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget)
            #expect(source.metadata.versionID == f.document.versionID)
            let range = try UTF16Range(location: UTF16Offset(0), length: f.document.utf16Count)
            #expect(try await source.text(in: range).text.utf8.elementsEqual(f.document.text.utf8))
            try await checkMappings(source, document: f.document)
            for index in f.chapters.indices {
                let page = try await source.chapters(start: index, limit: 1)
                let actual = try #require(page.first), expected = f.chapters[index]
                #expect(actual.id == expected.id && actual.title.map { Data($0.utf8) } == expected.title.map { Data($0.utf8) })
                #expect(actual.utf16Range == expected.utf16Range && actual.rawByteRange == expected.rawByteRange)
            }
            #expect(try await source.chapters(start: f.chapters.count, limit: 1).isEmpty)
            await source.close()
        }
    }
    @Test func crossChecksumPagesCheckpointsAndLongParagraphsKeepGlobalCoordinates() async throws {
        let text = "第一章 起点\r\n" + String(repeating: "a中😀e\u{301}", count: 4500) + "\r\n第二章 末尾\r\n终"
        let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget)
        let boundaries = f.document.offsets.boundaries
        for index in stride(from: 250, to: boundaries.count - 20, by: 251) {
            let first = boundaries[index], last = boundaries[index + 20]
            let range = try UTF16Range(location: first.utf16, length: last.utf16.value - first.utf16.value)
            let actual = try await source.text(in: range)
            #expect(actual.text == (f.document.text as NSString).substring(with: range.nsRange))
            #expect(actual.rawRange.location == first.rawByte && actual.rawRange.end == last.rawByte)
        }
        let eof = try UTF16Range(location: UTF16Offset(f.document.utf16Count), length: 0)
        #expect(try await source.text(in: eof).text.isEmpty)
        await source.close()
        for count in [255, 256, 257, 512] {
            let edge = try await DerivedBookFixture(bytes: Data(String(repeating: "a", count: count).utf8))
            defer { edge.remove() }
            try await edge.service.buildDerivedBook(id: edge.book.id, budget: edge.budget)
            let reader = try await edge.service.openDerivedBook(id: edge.book.id, budget: edge.budget)
            #expect(try await reader.rawByteOffset(for: UTF16Offset(count)).value == count)
            #expect(try await reader.utf16Offset(for: RawByteOffset(count)).value == count)
            await reader.close()
        }
    }
    @Test func globalGraphemesIncludeLongRegionalIndicatorRunsAndMultiPageClusters() async throws {
        let text = String(repeating: "🇨", count: 5000) + "a" + String(repeating: "\u{301}", count: 20000) + "👩🏽‍💻\r\n末"
        let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget)
        let full = f.document.text as NSString
        for value in Array(stride(from: 0, to: full.length, by: 127)) + [8191, 8192, 16383, 16384, 24576, full.length] {
            let expected = value == full.length ? value : full.rangeOfComposedCharacterSequence(at: value).location
            #expect(try await source.composedStart(at: value) == expected)
        }
        // Preserve the engine's inability-to-advance condition instead of inventing scalar truncation.
        let clusterStart = 10000
        #expect(try await source.composedStart(at: clusterStart + 1024) == clusterStart)
        await source.close()
    }
    @Test func strictUTF16HandlesNonzeroDataIndicesAndRejectsUnpairedSurrogates() throws {
        let full = Data([9, 9, 0x3D, 0xD8, 0, 0xDE, 0x41, 0])
        let slice = full.dropFirst(2)
        #expect(slice.startIndex > 0)
        #expect(try DerivedBookFormat.strictUTF16(slice) == "😀A")
        #expect(try DerivedBookFormat.strictUTF16(slice) == DerivedBookFormat.strictUTF16(Data(slice)))
        let malformed: [[UInt8]] = [[0], [0, 0xD8], [0, 0xDC], [0, 0xD8, 65, 0]]
        for bytes in malformed {
            #expect(throws: DerivedStorageError.corruptArtifact) { try DerivedBookFormat.strictUTF16(Data(bytes)) }
        }
    }
    @Test func malformedAuthenticatedHeaderLengthsOverlapsAndSchemaAreRejectedBeforeAllocation() async throws {
        for variant in 0..<4 {
            let f = try await DerivedBookFixture(); defer { f.remove() }
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            try await f.rewriteHeader { object in
                if variant == 0 { object["payloadBytes"] = Int.max }
                if variant == 1 {
                    var sections = try #require(object["sections"] as? [[String: Any]])
                    sections[1]["offset"] = 0; object["sections"] = sections
                }
                if variant == 2 {
                    var sections = try #require(object["sections"] as? [[String: Any]])
                    sections[0]["length"] = UInt64.max; object["sections"] = sections
                }
                if variant == 3 { object["schema"] = 999 }
            }
            await #expect(throws: DerivedStorageError.self) { try await f.service.openDerivedBook(id: f.book.id, budget: f.budget) }
            #expect(try await f.store.book(id: f.book.id)?.versionID == f.book.versionID)
        }
    }
    @Test func everyPayloadSectionDetectsBitChangesEvenWhenUTF16StillLooksValid() async throws {
        let text = "第一章 起点\n" + String(repeating: "abcdef", count: 4000) + "\n第二章 末尾\nend"
        for section in 0..<6 {
            let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget)
            try await f.changeByte(section: section); await source.releasePageCache()
            switch section {
            case 0: await #expect(throws: DerivedStorageError.corruptArtifact) { try await source.text(in: UTF16Range(location: UTF16Offset(0), length: 10)) }
            case 1, 2: await #expect(throws: DerivedStorageError.corruptArtifact) { try await source.rawByteOffset(for: UTF16Offset(0)) }
            case 3: await #expect(throws: DerivedStorageError.corruptArtifact) { try await source.composedStart(at: 1) }
            default: await #expect(throws: DerivedStorageError.corruptArtifact) { try await source.chapters(start: 0, limit: 1) }
            }
            await #expect(throws: DerivedStorageError.missingArtifact) { try await f.service.openDerivedBook(id: f.book.id, budget: f.budget) }
            await source.close()
        }
    }
    @Test func truncatedFilesAndCorruptDigestTablesInvalidateAndPermitOneExplicitRebuild() async throws {
        for truncate in [true, false] {
            let f = try await DerivedBookFixture(); defer { f.remove() }
            let anchor = try await f.savedAnchor()
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            let (url, pointer) = try await f.artifact()
            let file = try FileHandle(forUpdating: url)
            if truncate { try file.truncate(atOffset: UInt64(pointer.byteCount / 2)) }
            else {
                let old = try DerivedBookFormat.read(file, offset: pointer.byteCount - 1, count: 1, maximumBytes: 1)
                try file.seek(toOffset: UInt64(pointer.byteCount - 1)); try file.write(contentsOf: Data([old[0] ^ 1]))
            }
            try file.close()
            let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget, rebuildIfNeeded: true)
            #expect(try await source.text(in: UTF16Range(location: UTF16Offset(0), length: 2)).text == "第一")
            await source.close()
            #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == anchor)
        }
    }
    @Test func queryBudgetsAndInvalidBoundariesDoNotDestroyAValidGeneration() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let budget = try DerivedBookFixture.limits(read: 2, chapters: 1)
        let source = try await f.service.openDerivedBook(id: f.book.id, budget: budget)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await source.text(in: UTF16Range(location: UTF16Offset(0), length: 3)) }
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await source.chapters(start: 0, limit: 2) }
        await #expect(throws: TXTError.invalidByteBoundary(RawByteOffset(-1))) { try await source.utf16Offset(for: RawByteOffset(-1)) }
        #expect(try await source.text(in: UTF16Range(location: UTF16Offset(0), length: 2)).text == "第一")
        await source.close()
        let again = try await f.service.openDerivedBook(id: f.book.id, budget: budget); await again.close()
    }
    @Test func fileReadsRejectOversizedOverflowAndPastEOFRequestsBeforeReserving() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let url = try await f.store.fileURL(bookID: f.book.id)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        #expect(throws: DerivedStorageError.budgetExceeded) { try DerivedBookFormat.read(file, offset: 0, count: 1000, maximumBytes: 16) }
        #expect(throws: DerivedStorageError.corruptArtifact) { try DerivedBookFormat.read(file, offset: Int.max, count: 1, maximumBytes: 16) }
        #expect(throws: DerivedStorageError.corruptArtifact) { try DerivedBookFormat.read(file, offset: f.book.byteCount, count: 1, maximumBytes: 16) }
        #expect(try DerivedBookFormat.read(file, offset: 0, count: 1, maximumBytes: 1) == f.document.originalBytes.prefix(1))
    }
}
