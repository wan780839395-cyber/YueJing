import CoreFoundation
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
            await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data(bytes), using: .utf8, chunkSize: 1) }
        }
        let malformedGB: [[UInt8]] = [[0x81, 0x30, 0x81], [0x81, 0x30, 0x81, 0xFF], [0x81, 0x7F], [0x80]]
        for bytes in malformedGB {
            await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data(bytes), using: .gb18030, chunkSize: 1) }
        }
        let malformedUTF16: [[UInt8]] = [[0xFF, 0xFE, 0x41], [0xFF, 0xFE, 0x00, 0xDC], [0xFF, 0xFE, 0x3D, 0xD8, 0x41, 0]]
        for bytes in malformedUTF16 {
            await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data(bytes), chunkSize: 1) }
        }
        await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0xFF, 0x81])) }
        await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0xFF, 0xFE]), using: .utf8) }
        await #expect(throws: TXTError.self) { try await TXTProcessor().decode(Data([0xFF, 0xFE, 0, 0])) }
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

    @Test func gbkConversionStagesSeparateLegacyIdentifierFromCP936() async throws {
        let cp936 = CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue)
        #expect(CFStringConvertEncodingToWindowsCodepage(cp936) == 936)
        #expect(CFStringConvertWindowsCodepageToEncoding(936) == cp936)
        #expect(CFStringIsEncodingAvailable(cp936))
        let converters: [(name: String, identifier: CFStringEncoding)] = [
            ("GBK_95", CFStringEncoding(CFStringEncodings.GBK_95.rawValue)), ("CP936", cp936)
        ]
        let fixtures: [(bytes: [UInt8], text: String)] = [
            ([0xD6, 0xD0], "\u{4E2D}"), ([0xCE, 0xC4], "\u{6587}"), ([0xC2, 0xA1], "\u{9686}")
        ]
        func hex(_ data: Data?) -> String {
            data.map { $0.map { String(format: "%02X", $0) }.joined() } ?? "nil"
        }
        for fixture in fixtures {
            let source = Data(fixture.bytes)
            for converter in converters {
                let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converter.identifier))
                let forward = String(data: source, encoding: stringEncoding)
                let reverse = forward.flatMap { $0.data(using: stringEncoding, allowLossyConversion: false) }
                let knownReverse = fixture.text.data(using: stringEncoding, allowLossyConversion: false)
                let scalars = forward.map { $0.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ",") } ?? "nil"
                // Synthetic bytes only. Do not require the legacy identifier to fail on every OS.
                print("GBK conversion stage codec=\(converter.name) cf=\(converter.identifier) ns=\(stringEncoding.rawValue) available=\(CFStringIsEncodingAvailable(converter.identifier)) source=\(hex(source)) forwardScalars=\(scalars) reverse=\(hex(reverse)) knownReverse=\(hex(knownReverse))")
                if converter.identifier == cp936 {
                    #expect(forward == fixture.text)
                    #expect(reverse == source)
                    #expect(knownReverse == source)
                }
            }
            let document = try await TXTProcessor().decode(source, using: .gbk, chunkSize: 1)
            #expect(document.text == fixture.text)
            #expect(document.originalBytes == source)
        }
    }

    @Test func gbkKnownMappingsPreserveStrictRoundTripAcrossChunks() async throws {
        // Microsoft's CP936 mapping published by Unicode: legal lead/trail boundaries and GBK extensions.
        let bytes = Data([0x81, 0x40, 0x81, 0x7E, 0x81, 0x80, 0x81, 0xFE, 0xFE, 0x40, 0xD6, 0xD0, 0xCE, 0xC4])
        let expected = "\u{4E02}\u{4E8A}\u{4E90}\u{4FA2}\u{FA0C}\u{4E2D}\u{6587}"
        let cp936 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue)))
        #expect(expected.data(using: cp936, allowLossyConversion: false) == bytes)
        for chunk in 1...bytes.count {
            let document = try await TXTProcessor().decode(bytes, using: .gbk, chunkSize: chunk)
            #expect(Data(document.text.utf8) == Data(expected.utf8))
            #expect(document.originalBytes == bytes)
            #expect(document.encoding == .gbk)
            #expect(document.text.data(using: cp936, allowLossyConversion: false) == bytes)
            for scalar in 0...7 {
                #expect(try document.offsets.rawByteOffset(for: UTF16Offset(scalar)) == RawByteOffset(scalar * 2))
            }
        }
        let compatible = try await TXTProcessor().decode(Data([0xD6, 0xD0, 0xCE, 0xC4]), chunkSize: 1)
        #expect(Set(compatible.compatibleEncodings) == Set([TXTEncoding.gb18030, .gbk]))
        #expect(compatible.text == "\u{4E2D}\u{6587}")
    }

    @Test func gbkAmbiguityPreviewRetainsExplicitChoice() async throws {
        let bytes = Data([0xC2, 0xA1])
        do {
            _ = try await TXTProcessor().decode(bytes, chunkSize: 1)
            Issue.record("GBK ambiguity was silently selected")
        } catch TXTError.ambiguousEncoding(let previews) {
            #expect(Set(previews.map(\.encoding)) == Set([TXTEncoding.utf8, .gb18030, .gbk]))
            #expect(previews.contains { $0.encoding == .gbk && $0.text == "\u{9686}" })
        }
        let selected = try await TXTProcessor().decode(bytes, using: .gbk, chunkSize: 1)
        #expect(selected.text == "\u{9686}")
        #expect(selected.originalBytes == bytes)
    }

    @Test func gbkRejectsMalformedAndGB18030OnlySequences() async throws {
        let malformed: [[UInt8]] = [
            [0x81], [0xFE], [0x80], [0xFF], [0x00], [0x81, 0x3F], [0x81, 0x7F],
            [0x81, 0xFF], [0xFE, 0x7F], [0x81, 0x30], [0x81, 0x30, 0x81],
            [0x81, 0x30, 0x81, 0x30], [0x94, 0x39, 0xFC, 0x36]
        ]
        for suffix in malformed {
            let source = Data([0x41] + suffix)
            for chunk in 1...source.count {
                do {
                    _ = try await TXTProcessor().decode(source, using: .gbk, chunkSize: chunk)
                    Issue.record("Malformed or GB18030-only bytes were accepted as GBK")
                } catch let error as TXTError {
                    #expect(error == .malformedInput(encoding: .gbk, byteOffset: RawByteOffset(1)))
                }
            }
        }
    }
}
