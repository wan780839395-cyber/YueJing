import Foundation

public enum TXTEncoding: String, CaseIterable, Sendable {
    case utf8 = "UTF-8"
    case utf16LE = "UTF-16LE"
    case utf16BE = "UTF-16BE"
    case gb18030 = "GB18030-2000"
    case gbk = "GBK-95"
}

public struct RawByteOffset: Equatable, Hashable, Sendable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public struct UTF16Offset: Equatable, Hashable, Sendable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public struct RawByteRange: Equatable, Sendable {
    public let location: RawByteOffset
    public let length: Int
    public var end: RawByteOffset { RawByteOffset(location.value + length) }

    public init(location: RawByteOffset, length: Int) throws {
        guard location.value >= 0, length >= 0,
              !location.value.addingReportingOverflow(length).overflow else { throw TXTError.invalidRange }
        self.location = location; self.length = length
    }
}

public struct UTF16Range: Equatable, Sendable {
    public let location: UTF16Offset
    public let length: Int
    public var end: UTF16Offset { UTF16Offset(location.value + length) }
    public var nsRange: NSRange { NSRange(location: location.value, length: length) }

    public init(location: UTF16Offset, length: Int) throws {
        guard location.value >= 0, location.value != NSNotFound, length >= 0,
              !location.value.addingReportingOverflow(length).overflow else { throw TXTError.invalidRange }
        self.location = location; self.length = length
    }
}

public struct TXTEncodingPreview: Equatable, Sendable {
    public let encoding: TXTEncoding
    public let text: String
}

public enum TXTError: Error, Equatable, Sendable {
    case invalidChunkSize
    case unsupportedBOM
    case conflictingBOM
    case malformedInput(encoding: TXTEncoding, byteOffset: RawByteOffset)
    case noSupportedEncoding
    case ambiguousEncoding([TXTEncodingPreview])
    case invalidRange
    case invalidByteBoundary(RawByteOffset)
    case invalidUTF16Boundary(UTF16Offset)
    case invalidLayout
    case paginationCannotAdvance(UTF16Offset)
    case invalidCoreTextRange
}

public struct TXTBoundary: Equatable, Sendable {
    public let rawByte: RawByteOffset
    public let utf16: UTF16Offset
}

/// Exact scalar boundaries after BOM removal and CRLF/CR -> LF normalization.
/// BOM interiors, CRLF interiors, encoded-scalar interiors and surrogate interiors have no mapping.
public struct TXTOffsetMap: Sendable {
    public let documentVersion: String
    public let boundaries: [TXTBoundary]

    public func utf16Offset(for raw: RawByteOffset) throws -> UTF16Offset {
        guard let match = exact(raw.value, key: { $0.rawByte.value }) else { throw TXTError.invalidByteBoundary(raw) }
        return match.utf16
    }

    public func rawByteOffset(for utf16: UTF16Offset) throws -> RawByteOffset {
        guard let match = exact(utf16.value, key: { $0.utf16.value }) else { throw TXTError.invalidUTF16Boundary(utf16) }
        return match.rawByte
    }

    public func rawByteRange(for range: UTF16Range) throws -> RawByteRange {
        let start = try rawByteOffset(for: range.location), end = try rawByteOffset(for: range.end)
        return try RawByteRange(location: start, length: end.value - start.value)
    }

    public func utf16Range(for range: RawByteRange) throws -> UTF16Range {
        let start = try utf16Offset(for: range.location), end = try utf16Offset(for: range.end)
        return try UTF16Range(location: start, length: end.value - start.value)
    }

    private func exact(_ value: Int, key: (TXTBoundary) -> Int) -> TXTBoundary? {
        var low = 0, high = boundaries.count
        while low < high {
            let middle = low + (high - low) / 2
            if key(boundaries[middle]) < value { low = middle + 1 } else { high = middle }
        }
        return low < boundaries.count && key(boundaries[low]) == value ? boundaries[low] : nil
    }
}

public struct TXTDocument: Sendable {
    public let documentID: String
    public let versionID: String
    public let originalBytes: Data
    public let encoding: TXTEncoding
    public let compatibleEncodings: [TXTEncoding]
    public let bomByteCount: Int
    public let text: String
    public let offsets: TXTOffsetMap
    public var utf16Count: Int { offsets.boundaries.last?.utf16.value ?? 0 }
    public static let normalizationVersion = "scalar-newline-lf-v1"
}

public struct TXTChapter: Sendable {
    public let id: String
    public let documentVersion: String
    /// Nil for original preamble / unsectioned text; no title is invented.
    public let title: String?
    public let utf16Range: UTF16Range
    public let rawByteRange: RawByteRange
}

public struct TXTPageLayout: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let fontSize: Double
    public let lineSpacing: Double

    public init(width: Double, height: Double, fontSize: Double = 18, lineSpacing: Double = 4) {
        self.width = width; self.height = height; self.fontSize = fontSize; self.lineSpacing = lineSpacing
    }
}

public struct TXTPage: Sendable {
    public let documentVersion: String
    public let utf16Range: UTF16Range
    public let rawByteRange: RawByteRange
}
