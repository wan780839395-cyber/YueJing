import Foundation
import Testing
@testable import TXTCore

struct TXTEncodingTests {
    @Test func autoDetectsASCIIUTF8AndGBCompatibleText() async throws {
        let processor = TXTProcessor()
        let ascii = try await processor.decode(Data("plain text\n".utf8), chunkSize: 1)
        #expect(ascii.encoding == .utf8)
        let utf8 = try await processor.decode(Data([0xE4, 0xB8, 0xAD]), chunkSize: 1)
        #expect(utf8.encoding == .utf8)
        #expect(utf8.text == "中")
        let gb = try await processor.decode(Data([0xD6, 0xD0, 0xCE, 0xC4]), chunkSize: 1)
        #expect(gb.encoding == .gb18030)
        #expect(gb.compatibleEncodings.contains(.gbk))
        #expect(gb.text == "中文")
    }

    @Test func gb18030FourByteScalarSurvivesEveryChunkSplit() async throws {
        let bytes = Data([0xD6, 0xD0, 0x94, 0x39, 0xFC, 0x36, 0x0D, 0x0A, 0xCE, 0xC4])
        #expect(try await TXTProcessor().decode(bytes, chunkSize: 1).encoding == .gb18030)
        for chunk in 1...7 {
            let document = try await TXTProcessor().decode(bytes, using: .gb18030, chunkSize: chunk)
            #expect(document.text == "中😀\n文")
            #expect(document.originalBytes == bytes)
            #expect(try document.offsets.rawByteOffset(for: UTF16Offset(3)) == RawByteOffset(6))
            #expect(try document.offsets.rawByteOffset(for: UTF16Offset(4)) == RawByteOffset(8))
            #expect(throws: TXTError.self) { try document.offsets.utf16Offset(for: RawByteOffset(4)) }
            #expect(throws: TXTError.self) { try document.offsets.rawByteOffset(for: UTF16Offset(2)) }
        }
    }

    @Test func utf16BOMEndianAndSurrogatePairsAreStrict() async throws {
        let little = Data([0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE, 0x0D, 0x00, 0x0A, 0x00, 0x41, 0x00])
        let big = Data([0xFE, 0xFF, 0xD8, 0x3D, 0xDE, 0x00, 0x00, 0x0D, 0x00, 0x0A, 0x00, 0x41])
        for bytes in [little, big] {
            for chunk in 1...5 {
                let document = try await TXTProcessor().decode(bytes, chunkSize: chunk)
                #expect(document.text == "😀\nA")
                #expect(document.bomByteCount == 2)
                #expect(try document.offsets.rawByteOffset(for: UTF16Offset(0)) == RawByteOffset(2))
                #expect(try document.offsets.rawByteOffset(for: UTF16Offset(2)) == RawByteOffset(6))
                #expect(try document.offsets.rawByteOffset(for: UTF16Offset(3)) == RawByteOffset(10))
            }
        }
    }

    @Test func ambiguousBytesRequireExplicitChoiceWithPreview() async throws {
        let bytes = Data([0xC2, 0xA1]) // UTF8 U+00A1, GBK/GB18030 隆: both structurally valid.
        do {
            _ = try await TXTProcessor().decode(bytes, chunkSize: 1)
            Issue.record("Ambiguous input was silently selected")
        } catch TXTError.ambiguousEncoding(let previews) {
            #expect(previews.contains { $0.encoding == .utf8 && $0.text == "¡" })
            #expect(previews.contains { $0.encoding == .gb18030 && $0.text == "隆" })
        }
        #expect(try await TXTProcessor().decode(bytes, using: .utf8).text == "¡")
        #expect(try await TXTProcessor().decode(bytes, using: .gbk).text == "隆")
    }

    @Test func malformedBytesNeverBecomeReplacementCharacters() async throws {
        let malformedUTF8: [[UInt8]] = [[0xF0, 0x9F], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
        for bytes in malformedUTF8 {
            #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data(bytes), using: .utf8, chunkSize: 1) }
        }
        let malformedGB: [[UInt8]] = [[0x81, 0x30, 0x81], [0x81, 0x30, 0x81, 0xFF], [0x81, 0x7F], [0x80]]
        for bytes in malformedGB {
            #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data(bytes), using: .gb18030, chunkSize: 1) }
        }
        let malformedUTF16: [[UInt8]] = [[0xFF, 0xFE, 0x41], [0xFF, 0xFE, 0x00, 0xDC], [0xFF, 0xFE, 0x3D, 0xD8, 0x41, 0]]
        for bytes in malformedUTF16 {
            #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data(bytes), chunkSize: 1) }
        }
        #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0xFF, 0x81])) }
        #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0xFF, 0xFE]), using: .utf8) }
        #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0xFF, 0xFE, 0, 0])) }
        let literalReplacement = try await TXTProcessor().decode(Data([0xEF, 0xBF, 0xBD]), using: .utf8)
        #expect(literalReplacement.text == "\u{FFFD}") // Present in the source, not inserted by recovery.
    }

    @Test func documentIdentityPreservesSourceAndVersionMeaning() async throws {
        var bytes = Data([0x41])
        let first = try await TXTProcessor().decode(bytes, using: .utf8, chunkSize: 1)
        let again = try await TXTProcessor().decode(bytes, using: .utf8, chunkSize: 99)
        let changedEncoding = try await TXTProcessor().decode(bytes, using: .gbk)
        #expect(first.documentID == again.documentID)
        #expect(first.versionID == again.versionID)
        #expect(first.documentID == changedEncoding.documentID)
        #expect(first.versionID != changedEncoding.versionID)
        bytes[0] = 0x42
        #expect(first.originalBytes == Data([0x41]))
        #expect(first.offsets.documentVersion == first.versionID)
    }
}
