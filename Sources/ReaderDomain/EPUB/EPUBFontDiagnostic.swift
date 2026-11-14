import Foundation

/// Local, bounded metadata only. Never contains CSS, URLs, paths, book identity or text.
/// Names are declarations, not proof of a font's vendor or installed identity.
public struct EPUBFontDiagnostic: Codable, Sendable, Equatable, Hashable {
    public enum Source: String, Codable, Sendable { case embedded, local, missing }
    public enum Format: String, Codable, Sendable { case ttf, otf, sfnt, woff, woff2, other, unspecified }
    public enum Outcome: String, Codable, Sendable {
        case verified, convertedWOFF, restoredIDPF, restoredAdobe, localOmitted, missingFile
        case unsupportedFormat, adobeObfuscationOmitted, obfuscationKeyUnavailable
        case invalidStructure, unsupportedSubset, omittedByChapterFallback
    }
    public let family: String?
    public let localName: String?
    public let source: Source
    public let format: Format
    public let declaredFormat: Format
    public let declaredMIME: Format
    public let outcome: Outcome
    /// Optional untrusted internal names; absent in legacy JSON.
    public let identity: EPUBFontIdentity?

    public init(family: String? = nil, localName: String? = nil, source: Source,
                format: Format = .unspecified, declaredFormat: Format = .unspecified,
                declaredMIME: Format = .unspecified, outcome: Outcome, identity: EPUBFontIdentity? = nil) {
        self.family = Self.safeName(family)
        self.localName = Self.safeName(localName)
        self.source = source; self.format = format
        self.declaredFormat = declaredFormat; self.declaredMIME = declaredMIME; self.outcome = outcome
        self.identity = identity
    }

    public static func safeName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) ||
                  CharacterSet.decimalDigits.contains($0) || " -_().".unicodeScalars.contains($0) }),
              !value.contains(".."), !value.lowercased().contains("www.") else { return nil }
        return value
    }

    public static func formatCategory(_ raw: String?) -> Format {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "": return .unspecified
        case "woff", "font/woff", "application/font-woff": return .woff
        case "woff2", "font/woff2", "application/font-woff2": return .woff2
        case "truetype", "truetype-aat", "font/ttf", "application/x-font-ttf",
             "application/x-font-truetype", "font/truetype": return .ttf
        case "opentype", "font/otf", "application/vnd.ms-opentype", "application/x-font-opentype",
             "application/font-opentype", "font/opentype": return .otf
        case "application/font-sfnt": return .sfnt
        default: return .other
        }
    }

    public static func bounded(_ rows: [Self]) -> [Self] {
        var seen = Set<Self>()
        return Array(rows.lazy.filter { seen.insert($0).inserted }.prefix(128))
    }

    public static func summary(_ rows: [Self], includeNames: Bool = false) -> String {
        let boundedRows = bounded(rows)
        let header = "字体声明诊断（最多128条；非当前加载结果；不含正文、路径或书籍哈希）"
        guard !boundedRows.isEmpty else { return header + "\n没有可用声明记录；不能据此判断字体均正常。" }
        return header + "\n" + boundedRows.enumerated().map { index, row in
            var line = "\(index + 1). source=\(row.source.rawValue) format=\(row.format.rawValue) cssFormat=\(row.declaredFormat.rawValue) mime=\(row.declaredMIME.rawValue) result=\(row.outcome.rawValue)"
            if includeNames {
                line += " family=\(safeName(row.family) ?? "[省略]")"
                if row.source == .local { line += " local=\(safeName(row.localName) ?? "[省略]")" }
                if let identity = row.identity {
                    line += " internalFamily=\(safeName(identity.family) ?? "[省略]")"
                    line += " fullName=\(safeName(identity.fullName) ?? "[省略]")"
                    line += " postScriptName=\(safeName(identity.postScriptName) ?? "[省略]")"
                    line += " version=\(safeName(identity.version) ?? "[省略]")"
                    line += " manufacturer(unverified)=\(safeName(identity.manufacturer) ?? "[省略]")"
                }
            }
            return line
        }.joined(separator: "\n")
    }
}
