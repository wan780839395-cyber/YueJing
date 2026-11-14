import Foundation

/// CSS Fonts 3 unicode-range, normalized without expanding individual codepoints.
/// Nil means invalid/over-budget; callers must not silently broaden that face.
enum EPUBUnicodeRange {
    static let maxBytes = 4096
    static let maxRanges = 128

    static func normalize(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= maxBytes,
              raw.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= maxRanges else { return nil }
        var ranges: [(UInt32, UInt32)] = []
        func hex(_ s: Substring) -> UInt32? {
            guard (1...6).contains(s.count), s.allSatisfy({ $0.isHexDigit }) else { return nil }
            return UInt32(s, radix: 16)
        }
        for part in parts {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard value.hasPrefix("U+") else { return nil }
            let body = value.dropFirst(2)
            let start: UInt32
            let end: UInt32
            if body.contains("?") {
                guard (1...6).contains(body.count), let first = body.firstIndex(of: "?"),
                      body[first...].allSatisfy({ $0 == "?" }), !body.contains("-") else { return nil }
                guard let low = hex(Substring(body.replacingOccurrences(of: "?", with: "0"))),
                      let high = hex(Substring(body.replacingOccurrences(of: "?", with: "F"))) else { return nil }
                start = low; end = high
            } else {
                let ends = body.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count), let low = hex(ends[0]),
                      let high = hex(ends[ends.count - 1]) else { return nil }
                start = low; end = high
            }
            guard start <= end, end <= 0x10FFFF else { return nil }
            ranges.append((start, end))
        }
        ranges.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var merged: [(UInt32, UInt32)] = []
        for range in ranges {
            if let last = merged.last, range.0 <= last.1 + 1 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else { merged.append(range) }
        }
        return merged.map { low, high in
            let prefix = "U+" + String(low, radix: 16, uppercase: true)
            return low == high ? prefix : prefix + "-" + String(high, radix: 16, uppercase: true)
        }.joined(separator: ",")
    }

    /// Preserve numeric lexemes (including leading zeroes), never Double formatting.
    static func normalize(tokens: [EPUBAuthorStyles.CSSToken]) -> String? {
        var raw = ""
        for token in tokens {
            switch token {
            case .ident(let value): raw += value
            case .number(_, let value, _): raw += value
            case .dimension(_, let value, let unit): raw += value + unit
            case .delim(let scalar):
                guard scalar == 43 || scalar == 45 || scalar == 63 else { return nil }
                raw.unicodeScalars.append(Unicode.Scalar(scalar)!)
            case .comma: raw += ","
            case .whitespace: raw += " "
            default: return nil
            }
            guard raw.utf8.count <= maxBytes else { return nil }
        }
        return normalize(raw)
    }
}
