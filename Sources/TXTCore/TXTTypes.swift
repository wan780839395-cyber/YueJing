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

/// One width byte per normalized scalar, plus absolute coordinates every 256 scalars.
/// A CRLF pair is one step; supplementary scalars advance UTF-16 by two units.
struct TXTOffsetIndex: Sendable {
    fileprivate static let checkpointStride = 256
    fileprivate var widths: [UInt8] = []
    fileprivate var checkpoints: [TXTBoundary]
    fileprivate var rawEnd: Int
    fileprivate var utf16End = 0

    init(rawStart: Int) {
        rawEnd = rawStart
        checkpoints = [TXTBoundary(rawByte: RawByteOffset(rawStart), utf16: UTF16Offset(0))]
    }

    mutating func append(rawLength: Int, utf16Length: Int) {
        // Each encoded scalar is at most four bytes; normalization may merge a CR and LF.
        precondition((1...8).contains(rawLength) && (1...2).contains(utf16Length))
        widths.append(UInt8((rawLength << 1) | (utf16Length - 1)))
        rawEnd += rawLength
        utf16End += utf16Length
        if widths.count % Self.checkpointStride == 0 {
            checkpoints.append(TXTBoundary(rawByte: RawByteOffset(rawEnd), utf16: UTF16Offset(utf16End)))
        }
    }
}

/// Exact scalar boundaries after BOM removal and CRLF/CR -> LF normalization.
/// BOM interiors, CRLF interiors, encoded-scalar interiors and surrogate interiors have no mapping.
public struct TXTOffsetMap: Sendable {
    public let documentVersion: String
    private let index: TXTOffsetIndex

    init(documentVersion: String, index: TXTOffsetIndex) {
        self.documentVersion = documentVersion
        self.index = index
    }

    public var boundaryCount: Int { index.widths.count + 1 }
    public var utf16Count: Int { index.utf16End }

    /// Compatibility snapshot: O(scalars) time and a newly allocated full boundary array.
    /// Normal lookup, document length, chapter splitting and pagination do not call this getter.
    public var boundaries: [TXTBoundary] {
        var result: [TXTBoundary] = []
        result.reserveCapacity(boundaryCount)
        var raw = index.checkpoints[0].rawByte.value, utf16 = 0
        result.append(TXTBoundary(rawByte: RawByteOffset(raw), utf16: UTF16Offset(utf16)))
        for width in index.widths {
            raw += Int(width >> 1)
            utf16 += Int(width & 1) + 1
            result.append(TXTBoundary(rawByte: RawByteOffset(raw), utf16: UTF16Offset(utf16)))
        }
        return result
    }

    public func utf16Offset(for raw: RawByteOffset) throws -> UTF16Offset {
        guard let match = exact(raw.value, rawCoordinates: true) else { throw TXTError.invalidByteBoundary(raw) }
        return match.utf16
    }

    public func rawByteOffset(for utf16: UTF16Offset) throws -> RawByteOffset {
        guard let match = exact(utf16.value, rawCoordinates: false) else { throw TXTError.invalidUTF16Boundary(utf16) }
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

    private func exact(_ value: Int, rawCoordinates: Bool) -> TXTBoundary? {
        var low = 0, high = index.checkpoints.count
        while low < high {
            let middle = low + (high - low) / 2
            let boundary = index.checkpoints[middle]
            let coordinate = rawCoordinates ? boundary.rawByte.value : boundary.utf16.value
            if coordinate <= value { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let checkpoint = low - 1
        var raw = index.checkpoints[checkpoint].rawByte.value
        var utf16 = index.checkpoints[checkpoint].utf16.value
        if (rawCoordinates ? raw : utf16) == value {
            return TXTBoundary(rawByte: RawByteOffset(raw), utf16: UTF16Offset(utf16))
        }
        let start = checkpoint * TXTOffsetIndex.checkpointStride
        let end = start + min(TXTOffsetIndex.checkpointStride, index.widths.count - start)
        for position in start..<end {
            let width = index.widths[position]
            raw += Int(width >> 1)
            utf16 += Int(width & 1) + 1
            let coordinate = rawCoordinates ? raw : utf16
            if coordinate == value { return TXTBoundary(rawByte: RawByteOffset(raw), utf16: UTF16Offset(utf16)) }
            if coordinate > value { return nil }
        }
        return nil
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
    public var utf16Count: Int { offsets.utf16Count }
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
