import Foundation
import Testing
@testable import TXTCore

struct TXTStorageTests {
    private struct Order: RandomNumberGenerator {
        var state: UInt64 = 0x5EED
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    private func reference(repeats: Int, rawStart: Int, raw: [Int], utf16: [Int]) -> [TXTBoundary] {
        var result = [TXTBoundary(rawByte: RawByteOffset(rawStart), utf16: UTF16Offset(0))]
        for block in 0..<repeats {
            for position in 1..<raw.count {
                result.append(TXTBoundary(rawByte: RawByteOffset(rawStart + block * raw.last! + raw[position]),
                    utf16: UTF16Offset(block * utf16.last! + utf16[position])))
            }
        }
        return result
    }

    private func check(_ document: TXTDocument, against expected: [TXTBoundary]) throws {
        #expect(document.offsets.boundaryCount == expected.count)
        #expect(document.utf16Count == expected.last?.utf16.value)
        // This small-fixture compatibility check intentionally materializes the snapshot once.
        #expect(document.offsets.boundaries == expected)
        var order = Order()
        for boundary in expected.shuffled(using: &order) {
            #expect(try document.offsets.utf16Offset(for: boundary.rawByte) == boundary.utf16)
            #expect(try document.offsets.rawByteOffset(for: boundary.utf16) == boundary.rawByte)
        }
        for start in [0, 1, 255, 256, 257, 511, 512, expected.count - 1] where start < expected.count {
            let end = min(expected.count - 1, start + 259)
            let raw = try RawByteRange(location: expected[start].rawByte, length: expected[end].rawByte.value - expected[start].rawByte.value)
            let utf16 = try UTF16Range(location: expected[start].utf16, length: expected[end].utf16.value - expected[start].utf16.value)
            #expect(try document.offsets.rawByteRange(for: utf16) == raw)
            #expect(try document.offsets.utf16Range(for: raw) == utf16)
        }
        #expect(throws: TXTError.self) { try document.offsets.rawByteOffset(for: UTF16Offset(Int.max)) }
        #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(Int.max)) }
    }

    @Test func utf8CheckpointsKeepMixedScalarAndCRLFBoundariesAcrossChunks() async throws {
        let unit = "A中😀e\u{301}\r\nB\rC\n", normalized = "A中😀e\u{301}\nB\nC\n"
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(contentsOf: String(repeating: unit, count: 67).utf8)
        let expected = reference(repeats: 67, rawStart: 3,
            raw: [0, 1, 4, 8, 9, 11, 13, 14, 15, 16, 17], utf16: [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])
        for chunk in [1, 2, 3, 4, 7, 31, 256, 4096] {
            let document = try await TXTProcessor().decode(bytes, chunkSize: chunk)
            #expect(Data(document.text.utf8) == Data(String(repeating: normalized, count: 67).utf8))
            #expect(document.originalBytes == bytes)
            try check(document, against: expected)
            for block in [0, 25, 26, 51, 52, 66] {
                for interior in [2, 3, 5, 6, 7, 10, 12] {
                    #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(3 + block * 17 + interior)) }
                }
                #expect(throws: TXTError.self) { try document.offsets.rawByteOffset(for: UTF16Offset(block * 11 + 3)) }
            }
        }
    }

    @Test func utf16CheckpointsPreserveSurrogatesAndFourByteCRLFSteps() async throws {
        let text = String(repeating: "A中😀e\u{301}\r\nB\rC\n", count: 53)
        let expected = reference(repeats: 53, rawStart: 2,
            raw: [0, 2, 4, 8, 10, 12, 16, 18, 20, 22, 24], utf16: [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])
        for encoding in [TXTEncoding.utf16LE, .utf16BE] {
            var bytes = Data(encoding == .utf16LE ? [0xFF, 0xFE] : [0xFE, 0xFF])
            bytes.append(try #require(text.data(using: encoding == .utf16LE ? .utf16LittleEndian : .utf16BigEndian)))
            for chunk in [1, 2, 3, 5, 257, 4096] {
                let document = try await TXTProcessor().decode(bytes, chunkSize: chunk)
                #expect(document.encoding == encoding)
                #expect(document.originalBytes == bytes)
                try check(document, against: expected)
                for raw in [1, 3, 5, 7, 8, 9, 13, 15, 16, 17, 2 + 25 * 24 + 14] {
                    #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(raw)) }
                }
                #expect(throws: TXTError.self) { try document.offsets.rawByteOffset(for: UTF16Offset(3)) }
            }
        }
    }

    @Test func gbCheckpointsKeepStrictScalarWidthsAndNormalizedNewlines() async throws {
        let fixtures: [(encoding: TXTEncoding, bytes: [UInt8], raw: [Int], utf16: [Int], text: String)] = [
            (.gb18030, [0xD6, 0xD0, 0x94, 0x39, 0xFC, 0x36, 0x0D, 0x0A, 0xCE, 0xC4], [0, 2, 6, 8, 10], [0, 1, 3, 4, 5], "中😀\n文"),
            (.gbk, [0xD6, 0xD0, 0x0D, 0x0A, 0xCE, 0xC4], [0, 2, 4, 6], [0, 1, 2, 3], "中\n文")
        ]
        for fixture in fixtures {
            var bytes = Data()
            for _ in 0..<173 { bytes.append(contentsOf: fixture.bytes) }
            let expected = reference(repeats: 173, rawStart: 0, raw: fixture.raw, utf16: fixture.utf16)
            for chunk in [1, 2, 3, 4, 7, 257] {
                let document = try await TXTProcessor().decode(bytes, using: fixture.encoding, chunkSize: chunk)
                #expect(document.text == String(repeating: fixture.text, count: 173))
                #expect(document.originalBytes == bytes)
                try check(document, against: expected)
            }
        }
    }

    @Test func streamingVersionHashKeepsExistingByteSequenceForEveryEncoding() async throws {
        let fixtures: [(encoding: TXTEncoding, bytes: [UInt8], identity: String, version: String)] = [
            (.utf8, [239, 187, 191, 65, 228, 184, 173, 240, 159, 152, 128, 101, 204, 129, 13, 10],
             "174417e4b8ec147de9f0c8e9803f59e8a795cd6d729f7633a6ff41fc17558925", "0e0569f8f2918db550401dc769534b62bf8d0113ca385e720ee4f4f2da4d05eb"),
            (.utf16LE, [255, 254, 65, 0, 45, 78, 61, 216, 0, 222, 101, 0, 1, 3, 13, 0, 10, 0],
             "7a8063c5189ffd50481280ea58a2e5adb9e7a5bc8529824e28d8cca72d49e426", "bee56471125a1b5d3e406a0f36b625c4d36dce7974a923f5ff90532c7ff61758"),
            (.utf16BE, [254, 255, 0, 65, 78, 45, 216, 61, 222, 0, 0, 101, 3, 1, 0, 13, 0, 10],
             "90ff4fae414ccb5a100b4b246eedb52ef4d040c4375e42d5945df4ac67b5e08f", "0a331a57db00024c9f69ca9e6d7e459c41b3d1dee1c845bac74fd62d41d85c41"),
            (.gb18030, [214, 208, 148, 57, 252, 54, 13, 10, 206, 196],
             "c64fc61e62b7bf1c0624d37c27ab4f33abf8f08e47948daaaae4cb74f0bef873", "b880731899fac145da0f92501b964d9a4e8832a8a528e17d58dc1490fc7d9adf"),
            (.gbk, [214, 208, 13, 10, 206, 196],
             "14c1516a6c7d2d1b972b2d332b936fe2714f58d181f1d8a4a9e931476c12f21b", "9ab96a2d78b97742d26fc66b5f399e711f3aadaaea1773c17e8ac036a0d16706")
        ]
        for fixture in fixtures {
            for chunk in [1, 2, 3, 7, 4096] {
                let document = try await TXTProcessor().decode(Data(fixture.bytes), using: fixture.encoding, chunkSize: chunk)
                #expect(document.documentID == fixture.identity)
                #expect(document.versionID == fixture.version)
                #expect(document.offsets.documentVersion == fixture.version)
            }
        }
    }

    @Test func automaticCandidatesDiscardLateFailuresAndCompareBeyondPreview() async throws {
        let prefix = String(repeating: "A\r\n", count: 100)
        var gb = Data(prefix.utf8); gb.append(contentsOf: [0xD6, 0xD0, 0xCE, 0xC4])
        for chunk in [1, 7, 256, 4096] {
            let document = try await TXTProcessor().decode(gb, chunkSize: chunk)
            #expect(document.encoding == .gb18030)
            #expect(document.compatibleEncodings == [.gb18030, .gbk])
            #expect(document.text == String(repeating: "A\n", count: 100) + "中文")
            #expect(try document.offsets.rawByteOffset(for: UTF16Offset(200)) == RawByteOffset(300))
            #expect(try document.offsets.rawByteOffset(for: UTF16Offset(202)) == RawByteOffset(304))
        }
        var ambiguous = Data(String(repeating: "A", count: 300).utf8); ambiguous.append(contentsOf: [0xC2, 0xA1])
        do {
            _ = try await TXTProcessor().decode(ambiguous, chunkSize: 1)
            Issue.record("Different text beyond identical previews was silently selected")
        } catch TXTError.ambiguousEncoding(let previews) {
            #expect(previews.map(\.encoding) == [.utf8, .gb18030, .gbk])
            #expect(previews.allSatisfy { $0.text == String(repeating: "A", count: 80) })
        }
        #expect(try await TXTProcessor().decode(ambiguous, using: .utf8).text.hasSuffix("¡"))
        #expect(try await TXTProcessor().decode(ambiguous, using: .gbk).text.hasSuffix("隆"))
    }

    @Test func streamedChapterLinesPreserveBlankLinesAndTerminalHeading() async throws {
        let preamble = "说明\r\n\r\n", block = "第1章 开始\r\n正文e\u{301}😀。\r\n\r\n", terminal = "第2章 终章\r\n"
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(contentsOf: (preamble + String(repeating: block, count: 300) + terminal).utf8)
        let processor = TXTProcessor()
        let document = try await processor.decode(bytes, chunkSize: 3)
        let chapters = try await processor.chapters(in: document)
        try #require(chapters.count == 302)
        #expect(chapters[0].title == nil)
        #expect(chapters.last?.title == "第2章 终章")
        var rawStarts = [3]
        rawStarts += (0..<300).map { 3 + preamble.utf8.count + $0 * block.utf8.count }
        rawStarts.append(3 + preamble.utf8.count + 300 * block.utf8.count)
        for index in chapters.indices {
            let chapter = chapters[index]
            #expect(chapter.rawByteRange.location.value == rawStarts[index])
            #expect(chapter.rawByteRange.end.value == (index + 1 < rawStarts.count ? rawStarts[index + 1] : bytes.count))
            #expect(try document.offsets.utf16Range(for: chapter.rawByteRange) == chapter.utf16Range)
            #expect(chapter.utf16Range.length > 0)
        }
        #expect(chapters.last?.utf16Range.end.value == document.utf16Count)
    }
}
