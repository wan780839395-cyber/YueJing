import Foundation

/// Unauthenticated font-supplied metadata, never proof of vendor, origin or license.
/// All fields use the diagnostic 128-byte safe-name policy; no URL fields are read.
public struct EPUBFontIdentity: Codable, Sendable, Equatable, Hashable {
    public let family: String?
    public let fullName: String?
    public let postScriptName: String?
    public let version: String?
    public let manufacturer: String?

    public init(family: String? = nil, fullName: String? = nil, postScriptName: String? = nil,
                version: String? = nil, manufacturer: String? = nil) {
        self.family = EPUBFontDiagnostic.safeName(family)
        self.fullName = EPUBFontDiagnostic.safeName(fullName)
        self.postScriptName = Self.safePostScriptName(postScriptName)
        self.version = EPUBFontDiagnostic.safeName(version)
        self.manufacturer = EPUBFontDiagnostic.safeName(manufacturer)
    }

    private enum CodingKeys: String, CodingKey { case family, fullName, postScriptName, version, manufacturer }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(family: try values.decodeIfPresent(String.self, forKey: .family),
                  fullName: try values.decodeIfPresent(String.self, forKey: .fullName),
                  postScriptName: try values.decodeIfPresent(String.self, forKey: .postScriptName),
                  version: try values.decodeIfPresent(String.self, forKey: .version),
                  manufacturer: try values.decodeIfPresent(String.self, forKey: .manufacturer))
    }

    private static func safePostScriptName(_ raw: String?) -> String? {
        guard let value = EPUBFontDiagnostic.safeName(raw), value.utf8.count <= 63,
              value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && ![40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains($0) }) else { return nil }
        return value
    }

    /// Call only AFTER structural verification of the final, decoded SFNT bytes.
    /// Not a font validator. Malformed/unsupported optional names return nil or are
    /// omitted individually; this API never throws or changes font/book acceptance.
    /// TTC/WOFF/WOFF2 and platform-specific legacy encodings are not decoded here.
    public static func extract(fromValidatedSFNT data: Data) -> Self? {
        guard data.count <= Limits.fontBytes else { return nil }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            NameReader(bytes: bytes).extract()
        }
    }

    // Independent ceilings, not trusted allocation sizes from font headers.
    private enum Limits {
        static let fontBytes = 8 * 1024 * 1024
        static let tables = 256
        static let nameBytes = 256 * 1024
        static let records = 1024
        static let languageTags = 64
        static let stringBytes = 1024
        static let totalStringBytes = 64 * 1024
    }

    private struct NameReader {
        let bytes: UnsafeRawBufferPointer

        private func fits(_ start: Int, _ length: Int, end: Int) -> Bool {
            start >= 0 && length >= 0 && start <= end && length <= end - start
        }

        // Every call is preceded by a containing header/record/string bounds check.
        private func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        private func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 |
                UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }

        func extract() -> EPUBFontIdentity? {
            guard bytes.count >= 12,
                  [UInt32(0x00010000), 0x4f54544f, 0x74727565].contains(u32(0)) else { return nil }
            let tables = u16(4)
            guard tables > 0, tables <= Limits.tables,
                  fits(12, tables * 16, end: bytes.count) else { return nil }
            let directoryEnd = 12 + tables * 16
            var name: (start: Int, length: Int)?
            var tableBytes = 0
            for index in 0..<tables {
                let record = 12 + index * 16
                guard let start = Int(exactly: u32(record + 8)),
                      let length = Int(exactly: u32(record + 12)),
                      start >= directoryEnd, fits(start, length, end: bytes.count),
                      length <= Limits.fontBytes - tableBytes else { return nil }
                tableBytes += length
                if u32(record) == 0x6e616d65 {
                    guard name == nil, length <= Limits.nameBytes else { return nil }
                    name = (start, length)
                }
            }
            guard let name, name.length >= 6 else { return nil }
            return readNames(start: name.start, length: name.length)
        }

        private func readNames(start: Int, length: Int) -> EPUBFontIdentity? {
            let end = start + length // Bounded by input before entry.
            let format = u16(start)
            let count = u16(start + 2)
            let storageOffset = u16(start + 4)
            guard format == 0 || format == 1, count <= Limits.records,
                  fits(6, count * 12, end: length) else { return nil }
            var metadataEnd = 6 + count * 12
            var languageCount = 0
            if format == 1 {
                guard fits(metadataEnd, 2, end: length) else { return nil }
                languageCount = u16(start + metadataEnd)
                metadataEnd += 2
                guard languageCount <= Limits.languageTags,
                      fits(metadataEnd, languageCount * 4, end: length) else { return nil }
                metadataEnd += languageCount * 4
            }
            guard storageOffset >= metadataEnd, storageOffset <= length else { return nil }
            let storage = start + storageOffset
            // Charge every declared name string, including duplicate/unsupported records.
            // Language strings are charged before decoding; exhaustion returns no identity.
            var total = 0
            for index in 0..<count {
                let size = u16(start + 6 + index * 12 + 8)
                guard size <= Limits.totalStringBytes - total else { return nil }
                total += size
            }
            var languages: [String?] = []
            for index in 0..<languageCount {
                let record = start + 6 + count * 12 + 2 + index * 4
                let size = u16(record)
                guard size <= Limits.totalStringBytes - total else { return nil }
                total += size
                let offset = u16(record + 2)
                let value = decode(start: storage + offset, length: size, end: end)
                // Language tags are only used for selection, never exported.
                languages.append(value.flatMap { tag in
                    guard !tag.isEmpty, tag.utf8.count <= 128,
                          tag.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                              (48...57).contains($0) || $0 == 45 }) else { return nil }
                    return tag.lowercased()
                })
            }
            var selected: [Int: (rank: Int, value: String)] = [:]
            for index in 0..<count {
                let record = start + 6 + index * 12
                let platform = u16(record), encoding = u16(record + 2)
                let language = u16(record + 4), id = u16(record + 6)
                guard [1, 4, 5, 6, 8, 16].contains(id),
                      (platform == 0 && (0...4).contains(encoding)) ||
                        (platform == 3 && [0, 1, 10].contains(encoding)) else { continue }
                let english: Bool
                if language >= 0x8000 {
                    let languageIndex = language - 0x8000
                    guard format == 1, languageIndex < languages.count,
                          let tag = languages[languageIndex] else { continue }
                    english = tag == "en" || tag.hasPrefix("en-")
                } else {
                    english = platform == 3 && language == 0x0409
                }
                let size = u16(record + 8), offset = u16(record + 10)
                guard let decoded = decode(start: storage + offset, length: size, end: end),
                      let value = (id == 6 ? EPUBFontIdentity.safePostScriptName(decoded) : EPUBFontDiagnostic.safeName(decoded)) else { continue }
                // Stable, locale-independent: English, then neutral Unicode, then
                // other languages; Unicode before Windows for an otherwise equal rank.
                let rank = (english ? 0 : (platform == 0 && language == 0 ? 1 : 2)) * 2 + (platform == 0 ? 0 : 1)
                if selected[id].map({ rank < $0.rank }) ?? true { selected[id] = (rank, value) }
            }
            let identity = EPUBFontIdentity(family: selected[16]?.value ?? selected[1]?.value,
                fullName: selected[4]?.value, postScriptName: selected[6]?.value,
                version: selected[5]?.value, manufacturer: selected[8]?.value)
            guard identity.family != nil || identity.fullName != nil || identity.postScriptName != nil ||
                    identity.version != nil || identity.manufacturer != nil else { return nil }
            return identity
        }

        private func decode(start: Int, length: Int, end: Int) -> String? {
            guard length > 0, length <= Limits.stringBytes, length.isMultiple(of: 2),
                  fits(start, length, end: end) else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(length / 2)
            var cursor = start
            let stop = start + length
            while cursor < stop {
                let unit = u16(cursor)
                cursor += 2
                if (0xd800...0xdbff).contains(unit) {
                    guard cursor < stop else { return nil }
                    let low = u16(cursor)
                    guard (0xdc00...0xdfff).contains(low) else { return nil }
                    units.append(UInt16(unit)); units.append(UInt16(low)); cursor += 2
                } else {
                    guard !(0xdc00...0xdfff).contains(unit) else { return nil }
                    units.append(UInt16(unit))
                }
            }
            // Replacement decoding cannot repair invalid input: surrogates checked above.
            return String(decoding: units, as: UTF16.self)
        }
    }
}
