import CoreFoundation
import CryptoKit
import Foundation

enum TXTDecoder {
    private struct Unit {
        let text: String
        let start: Int
        let length: Int
        var end: Int { start + length }
    }

    static func decode(_ data: Data, using requested: TXTEncoding?, chunkSize: Int) throws -> TXTDocument {
        guard chunkSize > 0 else { throw TXTError.invalidChunkSize }
        let bytes = Array(data)
        let prefix = Array(bytes.prefix(4))
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
            let units = try scan(bytes, encoding: requested, start: start, chunkSize: chunkSize)
            return document(data, encoding: requested, compatible: [requested], start: start, units: units)
        }
        if let bom {
            let units = try scan(bytes, encoding: bom.encoding, start: bom.length, chunkSize: chunkSize)
            return document(data, encoding: bom.encoding, compatible: [bom.encoding], start: bom.length, units: units)
        }

        var variants: [(encoding: TXTEncoding, units: [Unit], text: String)] = []
        for encoding in [TXTEncoding.utf8, .gb18030, .gbk] {
            do {
                let units = try scan(bytes, encoding: encoding, start: 0, chunkSize: chunkSize)
                variants.append((encoding, units, normalize(units, start: 0).text))
            } catch let error as TXTError {
                if case .malformedInput = error { continue }
                throw error
            }
        }
        guard !variants.isEmpty else { throw TXTError.noSupportedEncoding }
        // Data equality is scalar-exact; Swift String equality would merge canonical equivalents.
        let distinctTexts = Set(variants.map { Data($0.text.utf8) })
        guard distinctTexts.count == 1 else {
            throw TXTError.ambiguousEncoding(variants.map { TXTEncodingPreview(encoding: $0.encoding, text: String($0.text.prefix(80))) })
        }
        let chosen = variants.first { $0.encoding == .utf8 } ?? variants[0]
        return document(data, encoding: chosen.encoding, compatible: variants.map { $0.encoding }, start: 0, units: chosen.units)
    }

    private static func scan(_ bytes: [UInt8], encoding: TXTEncoding, start: Int, chunkSize: Int) throws -> [Unit] {
        var pending: [UInt8] = [], absolute = start, position = start, units: [Unit] = []
        while position < bytes.count {
            try Task.checkCancellation()
            let end = position + min(chunkSize, bytes.count - position)
            pending.append(contentsOf: bytes[position..<end]); position = end
            var consumed = 0
            while consumed < pending.count {
                guard let value = try next(pending, at: consumed, encoding: encoding, absolute: absolute + consumed) else { break }
                units.append(Unit(text: value.text, start: absolute + consumed, length: value.length))
                consumed += value.length
            }
            if consumed > 0 { pending.removeFirst(consumed); absolute += consumed }
        }
        guard pending.isEmpty else { throw TXTError.malformedInput(encoding: encoding, byteOffset: RawByteOffset(absolute)) }
        return units
    }

    /// Nil means an incomplete scalar to carry to the next byte chunk, never a replacement character.
    private static func next(_ bytes: [UInt8], at index: Int, encoding: TXTEncoding,
                             absolute: Int) throws -> (text: String, length: Int)? {
        let available = bytes.count - index, first = bytes[index]
        func invalid() -> TXTError { .malformedInput(encoding: encoding, byteOffset: RawByteOffset(absolute)) }
        func scalar(_ value: UInt32, length: Int) throws -> (String, Int) {
            // Embedded NUL is outside this TXT contract; BOM-less UTF16 requires an explicit choice.
            guard value != 0, let character = Unicode.Scalar(value) else { throw invalid() }
            return (String(character), length)
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
                  text.data(using: stringEncoding, allowLossyConversion: false) == source else { throw invalid() }
            return (text, length)
        }
    }

    private static func normalize(_ units: [Unit], start: Int) -> (text: String, boundaries: [TXTBoundary]) {
        var text = "", position = 0, index = 0
        var boundaries = [TXTBoundary(rawByte: RawByteOffset(start), utf16: UTF16Offset(0))]
        while index < units.count {
            let unit = units[index]
            var value = unit.text, end = unit.end
            if value == "\r" {
                value = "\n"
                if index + 1 < units.count, units[index + 1].text == "\n" { index += 1; end = units[index].end }
            }
            text.append(contentsOf: value); position += value.utf16.count
            boundaries.append(TXTBoundary(rawByte: RawByteOffset(end), utf16: UTF16Offset(position)))
            index += 1
        }
        return (text, boundaries)
    }

    private static func document(_ data: Data, encoding: TXTEncoding, compatible: [TXTEncoding],
                                 start: Int, units: [Unit]) -> TXTDocument {
        let normalized = normalize(units, start: start)
        func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let identity = digest(data)
        var material = Data("\(identity)|\(encoding.rawValue)|\(TXTDocument.normalizationVersion)|".utf8)
        material.append(contentsOf: normalized.text.utf8)
        let version = digest(material)
        return TXTDocument(documentID: identity, versionID: version, originalBytes: data, encoding: encoding,
            compatibleEncodings: compatible, bomByteCount: start, text: normalized.text,
            offsets: TXTOffsetMap(documentVersion: version, boundaries: normalized.boundaries))
    }
}
