import CryptoKit
import Foundation
import TXTCore

enum DerivedBookFormat {
    static let headerBytes = 4096
    static let pageBytes = 16384 // Logical checksum/I/O unit, not an assumed hardware page size.
    static let graphemeUnits = 8192
    static let graphemeRecordBytes = 8 + graphemeUnits / 8
    static let chapterRecordBytes = 48
    static let magic = Data("YJPACK01".utf8)
    static let decoderRevision = "strict-foundation-scalar-v1"
    static let chapterRevision = "whole-lf-heading-v1"
    static var graphemeRevision: String { "nsstring-composed-v1|" + ProcessInfo.processInfo.operatingSystemVersionString }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isGeneration(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw DerivedStorageError.corruptArtifact }; return value
    }
    static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard a >= 0, b >= 0, !overflow else { throw DerivedStorageError.corruptArtifact }; return value
    }
    static func integer(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw DerivedStorageError.corruptArtifact }; return Int(value)
    }
    static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count, data.count - offset >= 8 else { throw DerivedStorageError.corruptArtifact }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[data.startIndex + offset + i]) << (8 * i) }
        return value
    }
    static func int(_ data: Data, at offset: Int) throws -> Int { try integer(uint64(data, at: offset)) }
    static func read(_ file: FileHandle, offset: Int, count: Int, maximumBytes: Int) throws -> Data {
        let end = try add(offset, count)
        guard count <= maximumBytes else { throw DerivedStorageError.budgetExceeded }
        guard try UInt64(end) <= file.seekToEnd() else { throw DerivedStorageError.corruptArtifact }
        try file.seek(toOffset: UInt64(offset))
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: count - result.count), !part.isEmpty else {
                throw DerivedStorageError.corruptArtifact
            }
            result.append(part)
        }
        return result
    }
    static func regularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DerivedStorageError.corruptArtifact }
    }
    static func strictUTF16(_ data: Data) throws -> String {
        guard data.count % 2 == 0 else { throw DerivedStorageError.corruptArtifact }
        var text = "", i = 0
        func unit(_ index: Int) -> UInt32 {
            UInt32(data[data.startIndex + index]) | (UInt32(data[data.startIndex + index + 1]) << 8)
        }
        while i < data.count {
            let first = unit(i); i += 2
            let value: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard i < data.count else { throw DerivedStorageError.corruptArtifact }
                let second = unit(i); i += 2
                guard (0xDC00...0xDFFF).contains(second) else { throw DerivedStorageError.corruptArtifact }
                value = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else { throw DerivedStorageError.corruptArtifact }; value = first
            }
            guard let scalar = Unicode.Scalar(value) else { throw DerivedStorageError.corruptArtifact }
            text.unicodeScalars.append(scalar)
        }
        return text
    }
}

struct DerivedSection: Codable, Sendable {
    let offset: UInt64
    let length: UInt64
}

/// Only six section descriptors. The potentially large page-digest table is outside this header.
struct DerivedManifest: Codable, Sendable {
    let schema: Int
    let bookID: String
    let versionID: String
    let generation: String
    let encoding: String
    let bomBytes: Int
    let rawBytes: Int
    let utf16Units: Int
    let scalars: Int
    let chapters: Int
    let normalization: String
    let decoder: String
    let chapterRules: String
    let graphemes: String
    let sections: [DerivedSection] // text, widths, checkpoints, grapheme records, chapters, titles
    let payloadBytes: Int
    let digestTableSHA256: String

    func header() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(self)
        guard json.count <= DerivedBookFormat.headerBytes - 16 else { throw DerivedStorageError.budgetExceeded }
        var result = DerivedBookFormat.magic
        DerivedBookFormat.append(UInt64(json.count), to: &result); result.append(json)
        result.append(Data(repeating: 0, count: DerivedBookFormat.headerBytes - result.count))
        return result
    }

    func validate(book: LibraryBook, pointer: DerivedPointer, budget: DerivedBookBudget, fileBytes: Int) throws {
        let f = DerivedBookFormat.self
        guard schema == 1, normalization == TXTDocument.normalizationVersion, decoder == f.decoderRevision,
              chapterRules == f.chapterRevision, graphemes == f.graphemeRevision else { throw DerivedStorageError.incompatibleFormat }
        guard f.isDigest(bookID), f.isDigest(versionID), f.isGeneration(generation),
              bookID == book.id, versionID == book.versionID, encoding == book.encodingRaw,
              pointer.bookID == bookID, pointer.versionID == versionID, pointer.generation == generation else {
            throw DerivedStorageError.versionMismatch
        }
        guard rawBytes == book.byteCount, utf16Units == book.utf16Count, rawBytes > 0, utf16Units > 0,
              (0...3).contains(bomBytes), bomBytes <= rawBytes, scalars > 0, scalars <= utf16Units,
              chapters > 0, chapters <= scalars, sections.count == 6, payloadBytes > 0,
              f.isDigest(digestTableSHA256), pointer.byteCount == fileBytes else { throw DerivedStorageError.corruptArtifact }
        let maximumUTF16 = try f.multiply(scalars, 2), maximumRaw = try f.multiply(scalars, 8)
        guard utf16Units <= maximumUTF16, rawBytes - bomBytes >= scalars,
              rawBytes - bomBytes <= maximumRaw else { throw DerivedStorageError.corruptArtifact }
        guard fileBytes <= budget.maximumArtifactBytes else { throw DerivedStorageError.budgetExceeded }
        let expected = [try f.multiply(utf16Units, 2), scalars,
                        try f.multiply(scalars / 256 + 1, 16),
                        try f.multiply((utf16Units - 1) / f.graphemeUnits + 1, f.graphemeRecordBytes),
                        try f.multiply(chapters, f.chapterRecordBytes)]
        var cursor = 0
        for (index, section) in sections.enumerated() {
            let start = try f.integer(section.offset), length = try f.integer(section.length)
            guard start == cursor, index >= 5 || length == expected[index] else { throw DerivedStorageError.corruptArtifact }
            cursor = try f.add(start, length)
        }
        guard cursor == payloadBytes, try f.integer(sections[5].length) <= f.multiply(chapters, 240) else {
            throw DerivedStorageError.corruptArtifact
        }
        let digestBytes = try f.multiply((payloadBytes - 1) / f.pageBytes + 1, 32)
        guard try f.add(f.headerBytes, digestBytes) <= budget.maximumMetadataBytes else { throw DerivedStorageError.budgetExceeded }
        guard try f.add(f.add(f.headerBytes, payloadBytes), digestBytes) == fileBytes else { throw DerivedStorageError.corruptArtifact }
    }
}
