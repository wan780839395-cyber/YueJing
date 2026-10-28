import CoreFoundation
import Foundation
import Testing
@testable import TXTCore

@Suite(.serialized)
struct TXTBlockDecoderTests {
    private func check(_ data: Data, encoding: TXTEncoding?, chunk: Int, allOffsets: Bool = true) async throws {
        let reference: TXTDocument
        do { reference = try LegacyTXTDecoderReference.decode(data, using: encoding, chunkSize: chunk) }
        catch let expected as TXTError {
            do {
                _ = try await TXTProcessor().decode(data, using: encoding, chunkSize: chunk)
                Issue.record("New decoder accepted bytes rejected by frozen reference")
            } catch let actual as TXTError {
                #expect(actual == expected)
                if case .ambiguousEncoding(let oldPreviews) = expected,
                   case .ambiguousEncoding(let newPreviews) = actual {
                    #expect(oldPreviews.map(\.encoding) == newPreviews.map(\.encoding))
                    #expect(oldPreviews.map { Data($0.text.utf8) } == newPreviews.map { Data($0.text.utf8) })
                }
            }
            return
        }
        let actual = try await TXTProcessor().decode(data, using: encoding, chunkSize: chunk)
        #expect(actual.originalBytes == reference.originalBytes)
        #expect(Data(actual.text.utf8) == Data(reference.text.utf8))
        #expect(actual.documentID == reference.documentID && actual.versionID == reference.versionID)
        #expect(actual.encoding == reference.encoding && actual.compatibleEncodings == reference.compatibleEncodings)
        #expect(actual.bomByteCount == reference.bomByteCount && actual.utf16Count == reference.utf16Count)
        #expect(actual.offsets.documentVersion == reference.offsets.documentVersion)
        let expectedBoundaries = reference.offsets.boundaries
        #expect(actual.offsets.boundaries == expectedBoundaries)
        if allOffsets {
            for boundary in expectedBoundaries {
                #expect(try actual.offsets.utf16Offset(for: boundary.rawByte) == boundary.utf16)
                #expect(try actual.offsets.rawByteOffset(for: boundary.utf16) == boundary.rawByte)
            }
            for raw in 0...data.count {
                do {
                    let expected = try reference.offsets.utf16Offset(for: RawByteOffset(raw))
                    #expect(try actual.offsets.utf16Offset(for: RawByteOffset(raw)) == expected)
                } catch let expected as TXTError {
                    #expect(throws: expected) { try actual.offsets.utf16Offset(for: RawByteOffset(raw)) }
                }
            }
            for utf16 in 0...reference.utf16Count {
                do {
                    let expected = try reference.offsets.rawByteOffset(for: UTF16Offset(utf16))
                    #expect(try actual.offsets.rawByteOffset(for: UTF16Offset(utf16)) == expected)
                } catch let expected as TXTError {
                    #expect(throws: expected) { try actual.offsets.rawByteOffset(for: UTF16Offset(utf16)) }
                }
            }
        }
    }

    @Test func mixedGBWidthsNewlinesAndTinyChunksMatchFrozenScalarDecoder() async throws {
        let gbk = Data([0x41, 0xD6, 0xD0, 0x0D, 0x0A, 0x81, 0x40, 0x81, 0x7E, 0x81, 0x80,
                        0x81, 0xFE, 0xFE, 0x40, 0x0D, 0xCE, 0xC4, 0x0D])
        let gb18030 = Data([0x41, 0xD6, 0xD0, 0x0D, 0x0A, 0x94, 0x39, 0xFC, 0x36, 0x42, 0x0D,
                            0x81, 0x30, 0x81, 0x30, 0x0A, 0xCE, 0xC4, 0x0D])
        for (encoding, data) in [(TXTEncoding.gbk, gbk), (.gb18030, gb18030)] {
            for chunk in [1, 2, 3, 4, 5, 7, 17, 4096, Int.max] { try await check(data, encoding: encoding, chunk: chunk) }
        }
        let converter = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))
        let marks = try #require("中e\u{301}😀\r\n文\r".data(using: converter, allowLossyConversion: false))
        for chunk in [1, 2, 3, 5, 4096] { try await check(marks, encoding: .gb18030, chunk: chunk) }
    }

    @Test func malformedAndTruncatedGBSequencesKeepEncodingAndFirstAbsoluteOffset() async throws {
        let suffixes: [[UInt8]] = [[0], [0x80], [0xFF], [0x81], [0x81, 0x3F], [0x81, 0x7F], [0x81, 0xFF],
            [0x81, 0x30], [0x81, 0x30, 0x81], [0x81, 0x30, 0x40, 0x30], [0x81, 0x30, 0x81, 0x40],
            [0xFE, 0x39, 0xFE, 0x39], [0x94, 0x39, 0xFC, 0x36]]
        for encoding in [TXTEncoding.gbk, .gb18030] {
            for suffix in suffixes {
                let data = Data([0x41, 0xD6, 0xD0] + suffix)
                for chunk in [1, 2, 3, 4, 5, 4096] { try await check(data, encoding: encoding, chunk: chunk) }
            }
        }
    }

    @Test func anEarlierMappingFailureIsNotHiddenByALaterStructuralFailure() async throws {
        // Structurally legal GB18030 pointer beyond the Unicode mapping range, then a later invalid byte.
        let data = Data([0x41, 0xFE, 0x39, 0xFE, 0x39, 0x00, 0xFF])
        #expect(throws: TXTError.malformedInput(encoding: .gb18030, byteOffset: RawByteOffset(1))) {
            try LegacyTXTDecoderReference.decode(data, using: .gb18030, chunkSize: 4096)
        }
        for chunk in [1, 2, 3, 4, 5, 6, 4096] { try await check(data, encoding: .gb18030, chunk: chunk) }
        // Canonical aliases are platform converter data. Compare actual old decisions, never assume an alias exists.
        let candidates: [[UInt8]] = [[0xA2, 0xE3], [0xA8, 0xBC], [0xFE, 0xFE], [0x81, 0x35, 0xF4, 0x37]]
        for encoding in [TXTEncoding.gbk, .gb18030] {
            for candidate in candidates {
                try await check(Data([0x41] + candidate + [0x00, 0xFF]), encoding: encoding, chunk: 4096)
            }
        }
    }

    @Test func unicodeBOMSurrogatesAutomaticChoicesAndInvalidChunksRemainIdentical() async throws {
        let utf8 = Data("A中😀e\u{301}\r\nZ\r".utf8)
        let le: [UInt8] = [0x41,0,0x2D,0x4E,0x3D,0xD8,0,0xDE,0x65,0,1,3,0x0D,0,0x0A,0,0x5A,0,0x0D,0]
        let be = stride(from: 0, to: le.count, by: 2).flatMap { [le[$0 + 1], le[$0]] }
        let cases: [(Data, TXTEncoding?)] = [(utf8, .utf8), (Data([0xEF,0xBB,0xBF]) + utf8, nil),
            (Data([0xFF,0xFE] + le), nil), (Data([0xFE,0xFF] + be), .utf16BE),
            (Data([0xFF,0xFE,0x41,0]), .utf8), (Data([0xC2,0xA1]), nil),
            (Data("plain\r\ntext\r".utf8), nil), (Data([0xD6,0xD0,0xCE,0xC4]), nil),
            (Data([0xFF,0xFE,0,0]), nil), (Data([0xFF,0xFE,0x3D,0xD8]), .utf16LE),
            (Data([0xED,0xA0,0x80]), .utf8), (Data([0xF0,0x80,0x80,0x80]), .utf8)]
        for (data, encoding) in cases {
            for chunk in [1, 2, 3, 5, 4096, Int.max, 0, -1] { try await check(data, encoding: encoding, chunk: chunk) }
        }
    }

    @Test func canonicalBlocksReduceConverterCallsWithoutChangingAnyCoordinateOrVersion() async throws {
        var bytes = Data()
        for _ in 0..<8192 { bytes.append(contentsOf: [0xD6, 0xD0]) }
        bytes.append(0x0A)
        let pair = AsyncStream<TXTDecodeMetrics>.makeStream(bufferingPolicy: .bufferingOldest(2))
        defer { pair.continuation.finish() }
        let consumer = Task { var values: [TXTDecodeMetrics] = []; for await value in pair.stream { values.append(value) }; return values }
        let oldStart = ContinuousClock().now
        let reference = try LegacyTXTDecoderReference.decode(bytes, using: .gbk, chunkSize: 4096)
        let oldElapsed = oldStart.duration(to: ContinuousClock().now).components
        let start = ContinuousClock().now
        let actual = try await TXTProcessor().decode(bytes, using: .gbk, chunkSize: 4096,
            observe: { _ = pair.continuation.yield($0) })
        let elapsed = start.duration(to: ContinuousClock().now).components
        pair.continuation.finish()
        let observations = await consumer.value
        let metrics = try #require(observations.first)
        #expect(observations.count == 1 && metrics.encoding == .gbk && metrics.requestedEncoding == .gbk)
        #expect(metrics.batchConversions > 0 && metrics.batchConversions < 8192 / 100)
        #expect(metrics.scalarConversions == 0 && metrics.fallbackBlocks == 0)
        #expect(metrics.roundTrips == metrics.batchConversions && metrics.largestGBInputBlock <= 64 * 1024)
        #expect(metrics.largestGBConversionBuffer <= 2 * 64 * 1024)
        #expect(Data(actual.text.utf8) == Data(reference.text.utf8) && actual.offsets.boundaries == reference.offsets.boundaries)
        #expect(actual.documentID == reference.documentID && actual.versionID == reference.versionID)
        #expect(metrics.scanConversionSeconds + metrics.normalizationIndexSeconds + metrics.rawHashSeconds
                + metrics.versionHashSeconds <= metrics.processorSeconds + 0.000001)
        // Synthetic counts/times only. A future Release run must record actual optimization/platform separately.
        let oldSeconds = Double(oldElapsed.seconds) + Double(oldElapsed.attoseconds) / 1e18
        let newSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("TXT_BLOCK_COMPARISON bytes=\(bytes.count) oldScalarConversions=8192 newBatchConversions=\(metrics.batchConversions) newScalarConversions=\(metrics.scalarConversions) oldReferenceSeconds=\(oldSeconds) newWrapperSeconds=\(newSeconds) processorSeconds=\(metrics.processorSeconds)")
        try await check(bytes, encoding: .gbk, chunk: 4096, allOffsets: false)
    }

    @Test func largeAndTinyInputBlocksKeepTheHardBoundAndScalarReference() async throws {
        var bytes = Data()
        for _ in 0..<17000 { bytes.append(contentsOf: [0xD6,0xD0,0x94,0x39,0xFC,0x36,0x0D,0x0A]) }
        for chunk in [65535, 65536, Int.max] {
            let pair = AsyncStream<TXTDecodeMetrics>.makeStream(bufferingPolicy: .bufferingOldest(1))
            defer { pair.continuation.finish() }
            let consumer = Task { var last: TXTDecodeMetrics?; for await value in pair.stream { last = value }; return last }
            _ = try await TXTProcessor().decode(bytes, using: .gb18030, chunkSize: chunk,
                observe: { _ = pair.continuation.yield($0) })
            pair.continuation.finish()
            let observed = await consumer.value
            let metric = try #require(observed)
            #expect(metric.largestGBInputBlock <= 65536 && metric.scalarConversions == 0)
            #expect(metric.largestGBConversionBuffer <= 131072)
            try await check(bytes, encoding: .gb18030, chunk: chunk, allOffsets: false)
        }
    }
}
