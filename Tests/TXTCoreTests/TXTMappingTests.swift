import Foundation
import Testing
@testable import TXTCore

struct TXTMappingTests {
    @Test func utf8ChunkBoundariesAndNewlinesKeepExactCoordinates() async throws {
        let original = Data([0x41, 0xF0, 0x9F, 0x98, 0x80, 0x65, 0xCC, 0x81, 0x0D, 0x0A, 0x42, 0x0D, 0x43, 0x0A])
        let expected = [(0, 0), (1, 1), (5, 3), (6, 4), (8, 5), (10, 6), (11, 7), (12, 8), (13, 9), (14, 10)]
        for chunkSize in 1...5 {
            let document = try await TXTProcessor().decode(original, using: .utf8, chunkSize: chunkSize)
            #expect(document.originalBytes == original)
            #expect(document.text == "A😀e\u{301}\nB\nC\n")
            #expect(document.utf16Count == 10)
            for (byte, utf16) in expected {
                #expect(try document.offsets.utf16Offset(for: RawByteOffset(byte)) == UTF16Offset(utf16))
                #expect(try document.offsets.rawByteOffset(for: UTF16Offset(utf16)) == RawByteOffset(byte))
            }
            for invalidByte in [2, 3, 4, 7, 9] {
                #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(invalidByte)) }
            }
            #expect(throws: TXTError.self) { try document.offsets.rawByteOffset(for: UTF16Offset(2)) }
            let newline = try UTF16Range(location: UTF16Offset(5), length: 1)
            #expect(try document.offsets.rawByteRange(for: newline) == RawByteRange(location: RawByteOffset(8), length: 2))
        }
    }

    @Test func emptyAndBOMOnlyDocumentsHaveOneContentBoundary() async throws {
        let empty = try await TXTProcessor().decode(Data())
        #expect(empty.text.isEmpty)
        #expect(empty.offsets.boundaries.count == 1)
        #expect(try empty.offsets.rawByteOffset(for: UTF16Offset(0)) == RawByteOffset(0))
        let bom = try await TXTProcessor().decode(Data([0xFF, 0xFE]), chunkSize: 1)
        #expect(bom.encoding == .utf16LE)
        #expect(bom.text.isEmpty)
        #expect(try bom.offsets.rawByteOffset(for: UTF16Offset(0)) == RawByteOffset(2))
        #expect(throws: TXTError.self) { try bom.offsets.utf16Offset(for: RawByteOffset(0)) }
    }

    @Test func rangesRejectInvalidBoundariesAndOverflow() async throws {
        let document = try await TXTProcessor().decode(Data("😀\r\nA".utf8), using: .utf8, chunkSize: 1)
        #expect(throws: TXTError.self) { try UTF16Range(location: UTF16Offset(NSNotFound), length: 0) }
        #expect(throws: TXTError.self) { try RawByteRange(location: RawByteOffset(Int.max), length: 1) }
        #expect(throws: TXTError.self) { try UTF16Range(location: UTF16Offset(0), length: -1) }
        #expect(throws: TXTError.self) { try document.offsets.rawByteRange(for: UTF16Range(location: UTF16Offset(1), length: 1)) }
        #expect(throws: TXTError.self) { try document.offsets.utf16Range(for: RawByteRange(location: RawByteOffset(5), length: 1)) }
        #expect(throws: TXTError.self) { try document.offsets.rawByteOffset(for: UTF16Offset(99)) }
        #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(-1)) }
        let end = try UTF16Range(location: UTF16Offset(document.utf16Count), length: 0)
        #expect(try document.offsets.rawByteRange(for: end).length == 0)
    }

    @Test func utf8BOMIsExcludedAndCombiningScalarsAreNotComposed() async throws {
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(contentsOf: "e\u{301}".utf8)
        let document = try await TXTProcessor().decode(bytes, chunkSize: 1)
        #expect(Array(document.text.utf16) == [0x65, 0x301])
        #expect(try document.offsets.rawByteOffset(for: UTF16Offset(0)) == RawByteOffset(3))
        #expect(try document.offsets.rawByteOffset(for: UTF16Offset(1)) == RawByteOffset(4))
        #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(1)) }
        await #expect(throws: TXTError.self) { try await TXTProcessor().decode(bytes, chunkSize: 0) }
        await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0x41, 0])) }
        #expect(try await TXTProcessor().decode(Data([0x41, 0]), using: .utf16LE).text == "A")
    }
}
