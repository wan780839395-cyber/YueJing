// Frozen a84811a decoder, test-only differential reference. Never used by production.
import CoreFoundation
import CryptoKit
import Foundation
@testable import TXTCore

enum LegacyTXTDecoderReference {
    private struct Decoded {
        let text: String
        let index: TXTOffsetIndex?
    }

    private struct Normalizer {
        var text = ""
        var index: TXTOffsetIndex?
        var pendingCRLength: Int?

        mutating func consume(_ scalar: Unicode.Scalar, rawLength: Int) {
            if let crLength = pendingCRLength {
                pendingCRLength = nil
                if scalar.value == 0x0A {
                    emit("\n", rawLength: crLength + rawLength)
                    return
                }
                emit("\n", rawLength: crLength)
            }
            if scalar.value == 0x0D { pendingCRLength = rawLength }
            else { emit(scalar, rawLength: rawLength) }
        }

        mutating func finish() -> Decoded {
            if let length = pendingCRLength { emit("\n", rawLength: length); pendingCRLength = nil }
            return Decoded(text: text, index: index)
        }

        private mutating func emit(_ scalar: Unicode.Scalar, rawLength: Int) {
            text.unicodeScalars.append(scalar)
            index?.append(rawLength: rawLength, utf16Length: scalar.value > 0xFFFF ? 2 : 1)
        }
    }

    static func decode(_ data: Data, using requested: TXTEncoding?, chunkSize: Int) throws -> TXTDocument {
        guard chunkSize > 0 else { throw TXTError.invalidChunkSize }
        // The borrowed buffer never escapes this synchronous decode call; original Data stays immutable.
        return try data.withUnsafeBytes { buffer in
            try decode(data, bytes: buffer.bindMemory(to: UInt8.self), using: requested, chunkSize: chunkSize)
        }
    }

    private static func decode(_ data: Data, bytes: UnsafeBufferPointer<UInt8>,
                               using requested: TXTEncoding?, chunkSize: Int) throws -> TXTDocument {
        let prefix = bytes.prefix(4)
        if prefix.starts(with: [0xFF, 0xFE, 0, 0]) || prefix.starts(with: [0, 0, 0xFE, 0xFF]) {
            throw TXTError.unsupportedBOM
        }
        let bom: (encoding: TXTEncoding, length: Int)?
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { bom = (.utf8, 3) }
        else if prefix.starts(with: [0xFF, 0xFE]) { bom = (.utf16LE, 2) }
        else if prefix.starts(with: [0xFE, 0xFF]) { bom = (.utf16BE, 2) }
        else { bom = nil }

        if let requested {
            if let bom, bom.encoding != requested { throw TXTError.conflictingBOM }
            let start = bom?.length ?? 0
            let decoded = try scan(bytes, encoding: requested, start: start, chunkSize: chunkSize, buildIndex: true)
            return document(data, encoding: requested, compatible: [requested], start: start, decoded: decoded)
        }
        if let bom {
            let decoded = try scan(bytes, encoding: bom.encoding, start: bom.length, chunkSize: chunkSize, buildIndex: true)
            return document(data, encoding: bom.encoding, compatible: [bom.encoding], start: bom.length, decoded: decoded)
        }

        var selected: (encoding: TXTEncoding, decoded: Decoded)?
        var compatible: [TXTEncoding] = []
        var previews: [TXTEncodingPreview] = []
        for encoding in [TXTEncoding.utf8, .gb18030, .gbk] {
            do {
                let decoded = try scan(bytes, encoding: encoding, start: 0, chunkSize: chunkSize, buildIndex: selected == nil)
                if let selected {
                    // Compare exact UTF-8 units, without canonical-equivalence merging or full Data copies.
                    let same = decoded.text.utf8.elementsEqual(selected.decoded.text.utf8)
                    if !same && previews.isEmpty {
                        let firstPreview = String(selected.decoded.text.prefix(80))
                        previews = compatible.map { TXTEncodingPreview(encoding: $0, text: firstPreview) }
                    }
                    if !previews.isEmpty {
                        previews.append(TXTEncodingPreview(encoding: encoding,
                            text: same ? previews[0].text : String(decoded.text.prefix(80))))
                    }
                } else {
                    // Candidate order is the existing UTF-8, GB18030, GBK preference order.
                    selected = (encoding, decoded)
                }
                compatible.append(encoding)
            } catch let error as TXTError {
                if case .malformedInput = error { continue }
                throw error
            }
        }
        guard let selected else { throw TXTError.noSupportedEncoding }
        guard previews.isEmpty else { throw TXTError.ambiguousEncoding(previews) }
        return document(data, encoding: selected.encoding, compatible: compatible, start: 0, decoded: selected.decoded)
    }

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>, encoding: TXTEncoding,
                             start: Int, chunkSize: Int, buildIndex: Bool) throws -> Decoded {
        var position = start, limit = start
        var normalized = Normalizer(index: buildIndex ? TXTOffsetIndex(rawStart: start) : nil)
        while limit < bytes.count {
            try Task.checkCancellation()
            limit += min(chunkSize, bytes.count - limit)
            while position < limit {
                guard let value = try next(bytes, at: position, limit: limit, encoding: encoding, absolute: position) else { break }
                normalized.consume(value.scalar, rawLength: value.length)
                position += value.length
            }
        }
        guard position == bytes.count else { throw TXTError.malformedInput(encoding: encoding, byteOffset: RawByteOffset(position)) }
        return normalized.finish()
    }

    /// Nil means an incomplete scalar to carry to the next byte chunk, never a replacement character.
    private static func next(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int, limit: Int, encoding: TXTEncoding,
                             absolute: Int) throws -> (scalar: Unicode.Scalar, length: Int)? {
        let available = limit - index, first = bytes[index]
        func invalid() -> TXTError { .malformedInput(encoding: encoding, byteOffset: RawByteOffset(absolute)) }
        func scalar(_ value: UInt32, length: Int) throws -> (Unicode.Scalar, Int) {
            // Embedded NUL is outside this TXT contract; BOM-less UTF16 requires an explicit choice.
            guard value != 0, let character = Unicode.Scalar(value) else { throw invalid() }
            return (character, length)
        }
        switch encoding {
        case .utf8:
            if first < 0x80 { return try scalar(UInt32(first), length: 1) }
            let length: Int, minimum: UInt32
            switch first {
            case 0xC2...0xDF: length = 2; minimum = 0x80
            case 0xE0...0xEF: length = 3; minimum = 0x800
            case 0xF0...0xF4: length = 4; minimum = 0x10000
            default: throw invalid()
            }
            guard available >= length else { return nil }
            var value = UInt32(first & UInt8(0x7F >> length))
            for offset in 1..<length {
                let byte = bytes[index + offset]
                guard (0x80...0xBF).contains(byte) else { throw invalid() }
                value = (value << 6) | UInt32(byte & 0x3F)
            }
            guard value >= minimum, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { throw invalid() }
            return try scalar(value, length: length)
        case .utf16LE, .utf16BE:
            guard available >= 2 else { return nil }
            func word(_ offset: Int) -> UInt32 {
                let a = UInt32(bytes[index + offset]), b = UInt32(bytes[index + offset + 1])
                return encoding == .utf16LE ? a | (b << 8) : (a << 8) | b
            }
            let high = word(0)
            if (0xD800...0xDBFF).contains(high) {
                guard available >= 4 else { return nil }
                let low = word(2)
                guard (0xDC00...0xDFFF).contains(low) else { throw invalid() }
                return try scalar(0x10000 + ((high - 0xD800) << 10) + low - 0xDC00, length: 4)
            }
            guard !(0xDC00...0xDFFF).contains(high) else { throw invalid() }
            return try scalar(high, length: 2)
        case .gb18030, .gbk:
            if first < 0x80 { return try scalar(UInt32(first), length: 1) }
            guard (0x81...0xFE).contains(first) else { throw invalid() }
            guard available >= 2 else { return nil }
            let second = bytes[index + 1], length: Int
            if (0x30...0x39).contains(second) {
                guard encoding == .gb18030 else { throw invalid() }
                guard available >= 4 else { return nil }
                guard (0x81...0xFE).contains(bytes[index + 2]), (0x30...0x39).contains(bytes[index + 3]) else { throw invalid() }
                length = 4
            } else {
                guard (0x40...0xFE).contains(second), second != 0x7F else { throw invalid() }
                length = 2
            }
            // Apple's CP936 converter implements GBK; the scanner still rejects its non-GBK byte forms.
            let identifier: CFStringEncoding = encoding == .gb18030 ? 0x0632
                : CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue)
            let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(identifier))
            let source = Data(bytes[index..<(index + length)])
            guard let text = String(data: source, encoding: stringEncoding), text.unicodeScalars.count == 1,
                  let character = text.unicodeScalars.first,
                  text.data(using: stringEncoding, allowLossyConversion: false) == source else { throw invalid() }
            return (character, length)
        }
    }

    private static func document(_ data: Data, encoding: TXTEncoding, compatible: [TXTEncoding],
                                 start: Int, decoded: Decoded) -> TXTDocument {
        guard let index = decoded.index else { preconditionFailure("Selected decode must have an offset index") }
        func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let identity = digest(data)
        var versionHash = SHA256()
        versionHash.update(data: Data("\(identity)|\(encoding.rawValue)|\(TXTDocument.normalizationVersion)|".utf8))
        updateUTF8(decoded.text, into: &versionHash)
        let version = versionHash.finalize().map { String(format: "%02x", $0) }.joined()
        return TXTDocument(documentID: identity, versionID: version, originalBytes: data, encoding: encoding,
            compatibleEncodings: compatible, bomByteCount: start, text: decoded.text,
            offsets: TXTOffsetMap(documentVersion: version, index: index))
    }

    private static func updateUTF8(_ text: String, into hash: inout SHA256) {
        if text.utf8.withContiguousStorageIfAvailable({ buffer in
            hash.update(bufferPointer: UnsafeRawBufferPointer(buffer))
            return true
        }) == true { return }
        // Non-contiguous strings use a bounded fallback, never a whole-book hash material buffer.
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for byte in text.utf8 {
            chunk.append(byte)
            if chunk.count == 64 * 1024 { hash.update(data: chunk); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { hash.update(data: chunk) }
    }
}
