import Foundation
import zlib

/// Bounded WOFF 1 container decoding, not a font-engine or metadata validator.
/// Callers must validate the returned SFNT and charge its size to the aggregate font budget.
internal enum EPUBWOFFDecoder {
    private static let maximumBytes = 8 * 1024 * 1024
    private static let headTag: UInt32 = 0x68656164

    private struct Table {
        let tag: UInt32
        let offset: Int
        let compressedLength: Int
        let originalLength: Int
        let checksum: UInt32
    }

    static func decode(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes else { throw EPUBError.limitExceeded }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw EPUBError.corruptResource }
        let signature = u32(bytes, 0)
        // No Brotli/WOFF 2 or collection support; neither is treated as an SFNT.
        guard signature != 0x774F4632, signature != 0x74746366 else {
            throw EPUBError.unsupportedContent
        }
        guard signature == 0x774F4646, bytes.count >= 44 else { throw EPUBError.corruptResource }
        let flavor = u32(bytes, 4)
        guard flavor != 0x74746366 else { throw EPUBError.unsupportedContent }
        guard flavor == 0x00010000 || flavor == 0x74727565 || flavor == 0x4F54544F,
              Int(u32(bytes, 8)) == bytes.count, u16(bytes, 14) == 0 else {
            throw EPUBError.corruptResource
        }
        let count = Int(u16(bytes, 12))
        guard count > 0, count <= 256 else { throw EPUBError.corruptResource }
        let directoryEnd = 44 + count * 20
        guard directoryEnd <= bytes.count else { throw EPUBError.corruptResource }
        let declaredSize = Int(u32(bytes, 16))
        guard declaredSize <= maximumBytes else { throw EPUBError.limitExceeded }
        var sfntSize = 12 + count * 16
        var tables: [Table] = []
        tables.reserveCapacity(count)
        var previousTag: UInt32?
        for index in 0..<count {
            let record = 44 + index * 20
            let tag = u32(bytes, record)
            guard bytes[record..<(record + 4)].allSatisfy({ (0x20...0x7E).contains($0) }),
                  previousTag.map({ $0 < tag }) ?? true else { throw EPUBError.corruptResource }
            previousTag = tag
            let offset = Int(u32(bytes, record + 4))
            let compressed = Int(u32(bytes, record + 8))
            let original = Int(u32(bytes, record + 12))
            guard compressed > 0, original > 0, compressed <= original,
                  offset >= directoryEnd, offset % 4 == 0,
                  offset <= bytes.count, compressed <= bytes.count - offset else {
                throw EPUBError.corruptResource
            }
            // Include SFNT directory and per-table padding in the decompressed size cap.
            guard original <= maximumBytes, aligned(original) <= maximumBytes - sfntSize else {
                throw EPUBError.limitExceeded
            }
            sfntSize += aligned(original)
            tables.append(Table(tag: tag, offset: offset, compressedLength: compressed,
                                originalLength: original, checksum: u32(bytes, record + 16)))
        }
        guard sfntSize == declaredSize else { throw EPUBError.corruptResource }
        guard let head = tables.first(where: { $0.tag == headTag }), head.originalLength >= 12 else {
            throw EPUBError.corruptResource
        }

        // Physical table order is independent of the tag-sorted directory. Only zero alignment
        // padding is permitted; rejecting gaps also prevents hidden, unaccounted trailing bytes.
        var cursor = directoryEnd
        for table in tables.sorted(by: { $0.offset < $1.offset }) {
            guard table.offset == cursor else { throw EPUBError.corruptResource }
            let end = table.offset + table.compressedLength
            let paddedEnd = table.offset + aligned(table.compressedLength)
            guard paddedEnd <= bytes.count, bytes[end..<paddedEnd].allSatisfy({ $0 == 0 }) else {
                throw EPUBError.corruptResource
            }
            cursor = paddedEnd
        }
        let metadataOffset = Int(u32(bytes, 24))
        let metadataLength = Int(u32(bytes, 28))
        let metadataOriginalLength = Int(u32(bytes, 32))
        if metadataOffset == 0 {
            guard metadataLength == 0, metadataOriginalLength == 0 else { throw EPUBError.corruptResource }
        } else {
            guard metadataOriginalLength > 0 else { throw EPUBError.corruptResource }
            guard metadataOriginalLength <= maximumBytes else { throw EPUBError.limitExceeded }
            try consumeAuxiliary(bytes, offset: metadataOffset, length: metadataLength, cursor: &cursor)
        }
        let privateOffset = Int(u32(bytes, 36))
        let privateLength = Int(u32(bytes, 40))
        if privateOffset == 0 {
            guard privateLength == 0 else { throw EPUBError.corruptResource }
        } else {
            try consumeAuxiliary(bytes, offset: privateOffset, length: privateLength, cursor: &cursor)
        }
        guard cursor == bytes.count else { throw EPUBError.corruptResource }
        // Auxiliary blocks are range/budget checked and intentionally ignored. In particular,
        // metadata is NOT inflated, XML-parsed, or represented as fully validated metadata.

        var sfnt = [UInt8](repeating: 0, count: sfntSize)
        put32(flavor, into: &sfnt, at: 0)
        put16(UInt16(count), into: &sfnt, at: 4)
        var power = 1
        var selector = 0
        while power * 2 <= count { power *= 2; selector += 1 }
        put16(UInt16(power * 16), into: &sfnt, at: 6)
        put16(UInt16(selector), into: &sfnt, at: 8)
        put16(UInt16(count * 16 - power * 16), into: &sfnt, at: 10)
        var destination = 12 + count * 16
        var headOffset = 0
        for (index, table) in tables.enumerated() {
            let stored = Array(bytes[table.offset..<(table.offset + table.compressedLength)])
            var decoded: [UInt8]
            if table.compressedLength == table.originalLength {
                decoded = stored
            } else {
                decoded = try inflateTable(stored, expected: table.originalLength)
            }
            if table.tag == headTag {
                // The head table checksum excludes checkSumAdjustment, even in the input.
                decoded.replaceSubrange(8..<12, with: [0, 0, 0, 0])
                headOffset = destination
            }
            guard checksum(decoded) == table.checksum else { throw EPUBError.corruptResource }
            let record = 12 + index * 16
            put32(table.tag, into: &sfnt, at: record)
            put32(table.checksum, into: &sfnt, at: record + 4)
            put32(UInt32(destination), into: &sfnt, at: record + 8)
            put32(UInt32(table.originalLength), into: &sfnt, at: record + 12)
            sfnt.replaceSubrange(destination..<(destination + decoded.count), with: decoded)
            destination += aligned(decoded.count)
        }
        put32(0xB1B0AFBA &- checksum(sfnt), into: &sfnt, at: headOffset + 8)
        return Data(sfnt)
    }

    private static func consumeAuxiliary(_ bytes: [UInt8], offset: Int, length: Int, cursor: inout Int) throws {
        guard offset % 4 == 0, offset == aligned(cursor), offset <= bytes.count,
              length > 0, length <= bytes.count - offset,
              bytes[cursor..<offset].allSatisfy({ $0 == 0 }) else { throw EPUBError.corruptResource }
        cursor = offset + length
    }

    private static func inflateTable(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var stream = z_stream()
        // inflateInit_ selects the zlib wrapper (not raw DEFLATE). Leave one spare byte to
        // detect an overlong stream without allowing attacker-controlled output allocation.
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw EPUBError.corruptResource
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: expected + 1)
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(expected + 1)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_in == input.count, stream.avail_in == 0,
              stream.total_out == expected else { throw EPUBError.corruptResource }
        output.removeLast()
        return output
    }

    private static func aligned(_ value: Int) -> Int { (value + 3) & ~3 }

    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var word: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            word |= UInt32(byte) << (24 - (index % 4) * 8)
            if index % 4 == 3 { sum &+= word; word = 0 }
        }
        if bytes.count % 4 != 0 { sum &+= word }
        return sum
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func put16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func put32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
    }
}
