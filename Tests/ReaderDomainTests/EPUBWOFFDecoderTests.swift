import Foundation
import Testing
import zlib
@testable import ReaderDomain

/// Synthetic container/byte tests only. These tables are not a renderable font.
struct EPUBWOFFDecoderTests {
    @Test func woffUncompressedMatchesGoldenSFNT() throws {
        let output = try EPUBWOFFDecoder.decode(Data(fixture()))
        #expect(output == Data(goldenSFNT()))
        #expect(output.count == 228)
        #expect(sum([UInt8](output)) == 0xB1B0AFBA)
    }

    @Test func woffCompressedMatchesGoldenSFNT() throws {
        let input = try compressedFixture()
        #expect(read32(input, 52) < read32(input, 56))
        #expect(read32(input, 72) < read32(input, 76))
        #expect(try EPUBWOFFDecoder.decode(Data(input)) == Data(goldenSFNT()))
    }

    @Test func woffMixedCompressionMatchesGoldenSFNT() throws {
        let compressed = try zipped([UInt8](repeating: 0, count: 128))
        #expect(try EPUBWOFFDecoder.decode(Data(fixture(storedGlyphs: compressed))) == Data(goldenSFNT()))
    }

    @Test func woffPhysicalTableOrderAndDataSliceAreIndependent() throws {
        let reversed = fixture(reversePhysical: true)
        #expect(read32(reversed, 48) > read32(reversed, 68))
        var prefixed = Data([0xFF, 0xFE, 0xFD])
        prefixed.append(contentsOf: reversed)
        let slice = prefixed.dropFirst(3)
        #expect(try EPUBWOFFDecoder.decode(slice) == Data(goldenSFNT()))
    }

    @Test func woffSupportedFlavorsPreserveVersionAndWholeChecksum() throws {
        for flavor in [UInt32(0x00010000), 0x74727565, 0x4F54544F] {
            var bytes = fixture()
            write32(flavor, &bytes, 4)
            let output = [UInt8](try EPUBWOFFDecoder.decode(Data(bytes)))
            #expect(read32(output, 0) == flavor)
            #expect(sum(output) == 0xB1B0AFBA)
            #expect(Array(output[44..<172]) == [UInt8](repeating: 0, count: 128))
        }
    }

    @Test func woffAuxiliaryPayloadIsSafelyIgnoredNotMetadataValidated() throws {
        // Deliberately not zlib/XML: the decoder promises only auxiliary envelope validation.
        let bytes = auxiliary(fixture(), metadata: [0xFF, 0x01, 0x02], privateData: [0xA5, 0x5A])
        #expect(try EPUBWOFFDecoder.decode(Data(bytes)) == Data(goldenSFNT()))
        #expect(try EPUBWOFFDecoder.decode(Data(auxiliary(fixture(), metadata: [1]))) == Data(goldenSFNT()))
        #expect(try EPUBWOFFDecoder.decode(Data(auxiliary(fixture(), privateData: [2]))) == Data(goldenSFNT()))
    }

    @Test func woffRejectsWOFF2AndCollections() throws {
        for signature in [UInt32(0x774F4632), 0x74746366] {
            var bytes = fixture()
            write32(signature, &bytes, 0)
            #expect(throws: EPUBError.unsupportedContent) { try EPUBWOFFDecoder.decode(Data(bytes)) }
        }
        var bytes = fixture()
        write32(0x74746366, &bytes, 4)
        #expect(throws: EPUBError.unsupportedContent) { try EPUBWOFFDecoder.decode(Data(bytes)) }
    }

    @Test func woffRejectsEveryTruncatedPrefix() throws {
        let bytes = fixture()
        for length in 0..<bytes.count {
            #expect(throws: EPUBError.corruptResource) { try EPUBWOFFDecoder.decode(Data(bytes.prefix(length))) }
        }
    }

    @Test func woffRejectsHeaderLengthReservedFlavorAndTableCount() throws {
        for (offset, value) in [(0, UInt32(0)), (4, 0), (8, 0), (8, 0xFFFFFFFF)] {
            var bytes = fixture()
            write32(value, &bytes, offset)
            expectCorrupt(bytes)
        }
        var reserved = fixture()
        reserved[15] = 1
        expectCorrupt(reserved)
        for count in [UInt16(0), 257, 65535] {
            var bytes = fixture()
            write16(count, &bytes, 12)
            expectCorrupt(bytes)
        }
        var missingDirectory = Array(fixture().prefix(44))
        write32(UInt32(missingDirectory.count), &missingDirectory, 8)
        expectCorrupt(missingDirectory)
    }

    @Test func woffRejectsDuplicateUnsortedAndNonASCIITags() throws {
        for tag in [UInt32(0x676C7966), 0x61616161, 0xFF656164] {
            var bytes = fixture()
            write32(tag, &bytes, 64)
            expectCorrupt(bytes)
        }
    }

    @Test func woffRejectsTableRangeAlignmentAndLengthViolations() throws {
        for (offset, value) in [
            (48, UInt32(0)), (48, 85), (48, 0xFFFFFFFC), (52, 0), (52, 129),
            (52, 0xFFFFFFFF), (56, 0), (68, 84)
        ] {
            var bytes = fixture()
            write32(value, &bytes, offset)
            expectCorrupt(bytes)
        }
        // A full range fits the file but starts inside the WOFF header/directory.
        var headerOverlap = fixture()
        write32(40, &headerOverlap, 48)
        expectCorrupt(headerOverlap)
    }

    @Test func woffRejectsOverlapsGapsNonzeroPaddingAndTrailingBytes() throws {
        var overlap = fixture()
        write32(208, &overlap, 68) // first table ends at 212
        expectCorrupt(overlap)
        var gap = fixture()
        gap.insert(contentsOf: [0, 0, 0, 0], at: 212)
        write32(216, &gap, 68)
        fixLength(&gap)
        expectCorrupt(gap)
        var padding = fixture()
        padding[padding.count - 1] = 1
        expectCorrupt(padding)
        var trailing = fixture()
        trailing.append(0)
        fixLength(&trailing)
        expectCorrupt(trailing)
    }

    @Test func woffRejectsInconsistentTotalSFNTSize() throws {
        for size in [UInt32(0), 227, 229] {
            var bytes = fixture()
            write32(size, &bytes, 16)
            expectCorrupt(bytes)
        }
    }

    @Test func woffRejectsInputDeclaredAndCumulativeOutputBudgets() throws {
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBWOFFDecoder.decode(Data(repeating: 0, count: 8 * 1024 * 1024 + 1))
        }
        var declared = fixture()
        write32(8 * 1024 * 1024 + 1, &declared, 16)
        expectLimit(declared)
        var original = fixture()
        write32(0xFFFFFFFF, &original, 56)
        expectLimit(original)
        // Each advertised table fits individually; together they exceed the decoded budget.
        var cumulative = fixture()
        write32(5 * 1024 * 1024, &cumulative, 56)
        write32(4 * 1024 * 1024, &cumulative, 76)
        expectLimit(cumulative)
        // Directory and padding are charged too, not just the raw table bytes.
        var directoryBudget = fixture()
        write32(8 * 1024 * 1024, &directoryBudget, 56)
        expectLimit(directoryBudget)
    }

    @Test func woffRejectsTableAndHeadChecksumCorruption() throws {
        for offset in [60, 80, 84, 212 + 12] {
            var bytes = fixture()
            bytes[offset] ^= 1
            expectCorrupt(bytes)
        }
        var compressed = try compressedFixture()
        compressed[60] ^= 1
        expectCorrupt(compressed)
    }

    @Test func woffHeadAdjustmentExcludedFromTableChecksumAndRebuilt() throws {
        var bytes = fixture()
        write32(0xFFFFFFFF, &bytes, 212 + 8)
        let output = [UInt8](try EPUBWOFFDecoder.decode(Data(bytes)))
        #expect(output == goldenSFNT())
        #expect(read32(output, 172 + 8) == 0x23BA5958)
        #expect(read32(output, 32) == 0x5F103CF5) // directory checksum, head adjustment zero
    }

    @Test func woffRejectsMissingOrTooShortHead() throws {
        var missing = fixture()
        write32(0x7A7A7A7A, &missing, 64)
        expectCorrupt(missing)
        expectCorrupt(fixture(rawHead: [UInt8](repeating: 0, count: 8)))
    }

    @Test func woffRejectsInvalidZlibAndAdlerChecksum() throws {
        var zippedGlyphs = try zipped([UInt8](repeating: 0, count: 128))
        zippedGlyphs[zippedGlyphs.count - 1] ^= 1
        expectCorrupt(fixture(storedGlyphs: zippedGlyphs))
        expectCorrupt(fixture(storedGlyphs: [0x78, 0x9C, 0xFF]))
    }

    @Test func woffRejectsTruncatedZlibStreamWithoutEnd() throws {
        let zippedGlyphs = try zipped([UInt8](repeating: 0, count: 128))
        expectCorrupt(fixture(storedGlyphs: Array(zippedGlyphs.dropLast())))
        expectCorrupt(fixture(storedGlyphs: Array(zippedGlyphs.dropLast(4))))
    }

    @Test func woffRejectsTrailingAndConcatenatedZlibStreams() throws {
        let zippedGlyphs = try zipped([UInt8](repeating: 0, count: 128))
        expectCorrupt(fixture(storedGlyphs: zippedGlyphs + [0]))
        expectCorrupt(fixture(storedGlyphs: zippedGlyphs + zippedGlyphs))
    }

    @Test func woffRejectsRawDeflateWithoutZlibWrapper() throws {
        let zippedGlyphs = try zipped([UInt8](repeating: 0, count: 128))
        let rawDeflate = Array(zippedGlyphs.dropFirst(2).dropLast(4))
        expectCorrupt(fixture(storedGlyphs: rawDeflate))
    }

    @Test func woffRejectsShortAndOverlongInflatedOutput() throws {
        for length in [127, 129, 512] {
            let stored = try zipped([UInt8](repeating: 0, count: length))
            expectCorrupt(fixture(storedGlyphs: stored)) // always advertises exactly 128
        }
    }

    @Test func woffRejectsInconsistentAuxiliaryPresence() throws {
        for offset in [28, 32, 40] {
            var absent = fixture()
            write32(1, &absent, offset)
            expectCorrupt(absent)
        }
        for offset in [28, 32] {
            var present = auxiliary(fixture(), metadata: [1, 2, 3])
            write32(0, &present, offset)
            expectCorrupt(present)
        }
        var emptyPrivate = auxiliary(fixture(), privateData: [1])
        write32(0, &emptyPrivate, 40)
        expectCorrupt(emptyPrivate)
    }

    @Test func woffRejectsAuxiliaryOverlapAlignmentOrderAndBounds() throws {
        for (offset, value) in [
            (24, UInt32(84)), (24, 269), (24, 0xFFFFFFFC), (28, 0xFFFFFFFF),
            (36, 84), (36, 273), (36, 0xFFFFFFFC), (40, 0xFFFFFFFF)
        ] {
            var bytes = auxiliary(fixture(), metadata: [1, 2, 3], privateData: [4, 5])
            write32(value, &bytes, offset)
            expectCorrupt(bytes)
        }
        var swapped = auxiliary(fixture(), metadata: [1, 2, 3], privateData: [4, 5])
        let meta = read32(swapped, 24)
        write32(read32(swapped, 36), &swapped, 24)
        write32(meta, &swapped, 36)
        expectCorrupt(swapped)
        var padding = auxiliary(fixture(), metadata: [1, 2, 3], privateData: [4])
        padding[Int(read32(padding, 36)) - 1] = 1
        expectCorrupt(padding)
    }

    @Test func woffRejectsAdvertisedMetadataExpansionOverBudget() throws {
        var bytes = auxiliary(fixture(), metadata: [1])
        write32(8 * 1024 * 1024 + 1, &bytes, 32)
        expectLimit(bytes)
    }

    @Test func woffAcceptsExactEightMiBDecodedBoundary() throws {
        let glyphLength = 8 * 1024 * 1024 - 100 // SFNT directory (44) plus padded head (56)
        let compressed = try zipped([UInt8](repeating: 0, count: glyphLength))
        let bytes = fixture(storedGlyphs: compressed, glyphLength: glyphLength)
        let output = [UInt8](try EPUBWOFFDecoder.decode(Data(bytes)))
        #expect(output.count == 8 * 1024 * 1024)
        #expect(sum(output) == 0xB1B0AFBA)
    }

    // Independent fixed golden: 2 tables, 128 zero glyph bytes, 54-byte head, 2 zero pad
    // bytes; checkSumAdjustment = 0x23BA5958, whole-font checksum = 0xB1B0AFBA.
    private func goldenSFNT() -> [UInt8] {
        hex("00010000 00020020 00010000 676c7966 00000000 0000002c 00000080 "
            + "68656164 5f103cf5 000000ac 00000036")
            + [UInt8](repeating: 0, count: 128)
            + hex("00010000 00000000 23ba5958 5f0f3cf5")
            + [UInt8](repeating: 0, count: 40)
    }

    private func headBytes() -> [UInt8] {
        hex("00010000 00000000 12345678 5f0f3cf5") + [UInt8](repeating: 0, count: 38)
    }

    private func fixture(storedGlyphs: [UInt8]? = nil, storedHead: [UInt8]? = nil,
                         reversePhysical: Bool = false, rawHead: [UInt8]? = nil,
                         glyphLength: Int = 128) -> [UInt8] {
        let glyphs = [UInt8](repeating: 0, count: glyphLength)
        let head = rawHead ?? headBytes()
        let raw = [glyphs, head]
        let stored = [storedGlyphs ?? glyphs, storedHead ?? head]
        let tags: [UInt32] = [0x676C7966, 0x68656164]
        var bytes = [UInt8](repeating: 0, count: 84)
        write32(0x774F4646, &bytes, 0)
        write32(0x00010000, &bytes, 4)
        write16(2, &bytes, 12)
        write32(UInt32(44 + pad(glyphs.count) + pad(head.count)), &bytes, 16)
        for index in (reversePhysical ? [1, 0] : [0, 1]) {
            let record = 44 + index * 20
            write32(tags[index], &bytes, record)
            write32(UInt32(bytes.count), &bytes, record + 4)
            write32(UInt32(stored[index].count), &bytes, record + 8)
            write32(UInt32(raw[index].count), &bytes, record + 12)
            var checksumBytes = raw[index]
            if index == 1, checksumBytes.count >= 12 {
                checksumBytes.replaceSubrange(8..<12, with: [0, 0, 0, 0])
            }
            write32(sum(checksumBytes), &bytes, record + 16)
            bytes += stored[index]
            bytes += [UInt8](repeating: 0, count: pad(bytes.count) - bytes.count)
        }
        fixLength(&bytes)
        return bytes
    }

    private func compressedFixture() throws -> [UInt8] {
        let glyphs = try zipped([UInt8](repeating: 0, count: 128))
        let head = try zipped(headBytes())
        #expect(glyphs.count < 128 && head.count < 54)
        return fixture(storedGlyphs: glyphs, storedHead: head)
    }

    private func auxiliary(_ input: [UInt8], metadata: [UInt8] = [], privateData: [UInt8] = []) -> [UInt8] {
        var bytes = input
        if !metadata.isEmpty {
            write32(UInt32(bytes.count), &bytes, 24)
            write32(UInt32(metadata.count), &bytes, 28)
            write32(100, &bytes, 32)
            bytes += metadata
        }
        if !privateData.isEmpty {
            bytes += [UInt8](repeating: 0, count: pad(bytes.count) - bytes.count)
            write32(UInt32(bytes.count), &bytes, 36)
            write32(UInt32(privateData.count), &bytes, 40)
            bytes += privateData
        }
        fixLength(&bytes)
        return bytes
    }

    private func zipped(_ input: [UInt8]) throws -> [UInt8] {
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compress2(destination.baseAddress!, &length, source.baseAddress!, uLong(input.count), Z_BEST_COMPRESSION)
            }
        }
        try #require(status == Z_OK)
        return Array(output.prefix(Int(length)))
    }

    private func expectCorrupt(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: EPUBError.corruptResource, sourceLocation: sourceLocation) {
            try EPUBWOFFDecoder.decode(Data(bytes))
        }
    }

    private func expectLimit(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: EPUBError.limitExceeded, sourceLocation: sourceLocation) {
            try EPUBWOFFDecoder.decode(Data(bytes))
        }
    }

    private func pad(_ value: Int) -> Int { (value + 3) / 4 * 4 }

    private func sum(_ input: [UInt8]) -> UInt32 {
        let bytes = input + [UInt8](repeating: 0, count: pad(input.count) - input.count)
        return stride(from: 0, to: bytes.count, by: 4).reduce(UInt32(0)) { $0 &+ read32(bytes, $1) }
    }

    private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func write16(_ value: UInt16, _ bytes: inout [UInt8], _ offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private func write32(_ value: UInt32, _ bytes: inout [UInt8], _ offset: Int) {
        for (index, shift) in [24, 16, 8, 0].enumerated() {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    private func fixLength(_ bytes: inout [UInt8]) { write32(UInt32(bytes.count), &bytes, 8) }

    private func hex(_ string: String) -> [UInt8] {
        let digits = Array(string.filter { !$0.isWhitespace })
        return stride(from: 0, to: digits.count, by: 2).map {
            UInt8(String(digits[$0...($0 + 1)]), radix: 16)!
        }
    }
}
