import CryptoKit
import Foundation

/// Conservative CSS tokenizer, selector/declaration whitelist, and SFNT font policy for EPUB author styles.
public enum EPUBAuthorStyles {
    public static let maxFontBytes = 8 * 1024 * 1024
    public static let maxTotalFontBytes = 32 * 1024 * 1024
    public static let maxExternalCSSBytes = 1 * 1024 * 1024
    public static let maxInlineCSSBytes = 512 * 1024
    public static let maxTotalChapterCSSBytes = 2 * 1024 * 1024

    public static let allowedFontMediaTypes: Set<String> = [
        "font/ttf",
        "font/otf"
    ]

    public static let allowedServedMediaTypes: Set<String> = [
        "application/xhtml+xml",
        "image/jpeg",
        "image/png",
        "image/webp",
        "font/ttf",
        "font/otf"
    ]

    public static let supportedFontManifestMediaTypes: Set<String> = [
        "font/ttf",
        "font/otf",
        "application/font-sfnt",
        "application/vnd.ms-opentype",
        "application/x-font-ttf",
        "application/x-font-truetype",
        "font/truetype",
        "application/x-font-opentype",
        "application/font-opentype",
        "font/opentype"
    ]

    public static func isAllowedServedMediaType(_ mediaType: String) -> Bool {
        allowedServedMediaTypes.contains(mediaType)
    }

    public static func isSupportedFontManifestMediaType(_ mediaType: String) -> Bool {
        supportedFontManifestMediaTypes.contains(mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func maximumServedBytes(forMediaType mediaType: String, limits: EPUBLimits = EPUBLimits()) -> Int? {
        switch mediaType {
        case "application/xhtml+xml":
            return limits.xhtmlBytes
        case "image/jpeg", "image/png", "image/webp":
            return limits.imageBytes
        case "font/ttf", "font/otf":
            return maxFontBytes
        default:
            return nil
        }
    }

    public static func scopeIdentifier(for canonicalPath: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "yj" + prefix
    }

    public static func rootRelativeEncodedPath(for canonicalPath: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/\\:?#%\"'()")
        let encoded = canonicalPath.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
        }.joined(separator: "/")
        return "/" + encoded
    }

    /// Validates raw font bytes for un-obfuscated SFNT TrueType/OpenType headers and non-overlapping table bounds.
    @discardableResult
    public static func verifyFontData(_ data: Data, declaredMediaType: String) throws -> String {
        guard !data.isEmpty else {
            throw EPUBError.corruptResource
        }
        guard data.count <= maxFontBytes else {
            throw EPUBError.limitExceeded
        }
        guard data.count >= 12 else {
            throw EPUBError.corruptResource
        }

        let declared = declaredMediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sfntVersion = uint32BE(data, at: 0)
        if sfntVersion == 0x774F4646 || sfntVersion == 0x774F4632 || sfntVersion == 0x74746366 {
            // 'wOFF', 'wOF2', 'ttcf'
            throw EPUBError.unsupportedContent
        }

        let isTTF = (sfntVersion == 0x00010000 || sfntVersion == 0x74727565) // 1.0 or 'true'
        let isOTF = (sfntVersion == 0x4F54544F) // 'OTTO'
        guard isTTF || isOTF else {
            throw EPUBError.corruptResource
        }

        let canonicalMediaType: String
        switch declared {
        case "font/ttf", "application/x-font-ttf", "application/x-font-truetype", "font/truetype":
            guard isTTF else { throw EPUBError.corruptResource }
            canonicalMediaType = "font/ttf"
        case "font/otf", "application/x-font-opentype", "application/font-opentype", "font/opentype":
            guard isOTF else { throw EPUBError.corruptResource }
            canonicalMediaType = "font/otf"
        case "application/font-sfnt", "application/vnd.ms-opentype":
            canonicalMediaType = isOTF ? "font/otf" : "font/ttf"
        default:
            throw EPUBError.unsupportedContent
        }

        let numTables = Int(uint16BE(data, at: 4))
        guard numTables > 0, numTables <= 256 else {
            throw EPUBError.corruptResource
        }
        let directoryEnd = 12 + numTables * 16
        guard data.count >= directoryEnd else {
            throw EPUBError.corruptResource
        }

        var tables: [String: (offset: Int, length: Int)] = [:]
        tables.reserveCapacity(numTables)
        var intervals: [(start: UInt64, end: UInt64)] = []
        intervals.reserveCapacity(numTables)

        for index in 0..<numTables {
            let recOffset = 12 + index * 16
            let tagBytes = [
                data[data.startIndex + recOffset],
                data[data.startIndex + recOffset + 1],
                data[data.startIndex + recOffset + 2],
                data[data.startIndex + recOffset + 3]
            ]
            guard tagBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
                  let tag = String(bytes: tagBytes, encoding: .ascii),
                  tables[tag] == nil else {
                throw EPUBError.corruptResource
            }
            let tableOffset = UInt64(uint32BE(data, at: recOffset + 8))
            let tableLength = UInt64(uint32BE(data, at: recOffset + 12))
            guard tableOffset >= UInt64(directoryEnd),
                  tableLength > 0,
                  tableOffset <= UInt64(data.count),
                  tableLength <= UInt64(data.count) - tableOffset else {
                throw EPUBError.corruptResource
            }
            tables[tag] = (offset: Int(tableOffset), length: Int(tableLength))
            intervals.append((start: tableOffset, end: tableOffset + tableLength))
        }

        intervals.sort { $0.start < $1.start }
        for index in 1..<intervals.count {
            guard intervals[index - 1].end <= intervals[index].start else {
                throw EPUBError.corruptResource
            }
        }

        guard let head = tables["head"], head.length >= 54 else {
            throw EPUBError.corruptResource
        }
        guard uint32BE(data, at: head.offset + 12) == 0x5F0F3CF5 else {
            throw EPUBError.corruptResource
        }

        if let maxp = tables["maxp"], maxp.length < 6 { throw EPUBError.corruptResource }
        if let hhea = tables["hhea"], hhea.length < 36 { throw EPUBError.corruptResource }
        if let name = tables["name"], name.length < 6 { throw EPUBError.corruptResource }
        if let cmap = tables["cmap"], cmap.length < 4 { throw EPUBError.corruptResource }
        if let os2 = tables["OS/2"], os2.length < 78 { throw EPUBError.corruptResource }

        if isOTF {
            guard tables["CFF "] != nil || tables["CFF2"] != nil else {
                throw EPUBError.corruptResource
            }
        } else {
            guard tables["glyf"] != nil else {
                throw EPUBError.corruptResource
            }
            if let loca = tables["loca"], loca.length < 2 {
                throw EPUBError.corruptResource
            }
        }

        return canonicalMediaType
    }

    /// Verifies an extracted font file on disk under `root` without following symlinks.
    public static func verifyExtractedFont(
        at canonicalPath: String,
        under root: URL,
        declaredMediaType: String,
        expectedSize: Int? = nil
    ) throws -> (mediaType: String, byteCount: Int) {
        let verifiedPath = try EPUBResourcePath.canonical(canonicalPath)
        guard verifiedPath == canonicalPath else {
            throw EPUBError.unsafePath
        }
        let fileURL = try safeExistingFileURL(for: verifiedPath, under: root)
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            throw EPUBError.unsafePath
        }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw EPUBError.corruptResource
        }
        if let expectedSize, size != expectedSize {
            throw EPUBError.corruptResource
        }
        guard size <= maxFontBytes else {
            throw EPUBError.limitExceeded
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count == size else {
            throw EPUBError.corruptResource
        }
        let canonicalMediaType = try verifyFontData(data, declaredMediaType: declaredMediaType)
        return (mediaType: canonicalMediaType, byteCount: size)
    }

    static func readExtractedCSS(at canonicalPath: String, under root: URL) throws -> String {
        let verifiedPath = try EPUBResourcePath.canonical(canonicalPath)
        guard verifiedPath == canonicalPath else {
            throw EPUBError.unsafePath
        }
        let fileURL = try safeExistingFileURL(for: verifiedPath, under: root)
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            throw EPUBError.unsafePath
        }
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw EPUBError.corruptResource
        }
        guard size <= maxExternalCSSBytes else {
            throw EPUBError.limitExceeded
        }
        if size == 0 {
            return ""
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count == size else {
            throw EPUBError.corruptResource
        }
        guard let decoded = decodeStrictCSSString(data) else {
            throw EPUBError.corruptResource
        }
        return decoded
    }

    private static func safeExistingFileURL(for canonicalPath: String, under root: URL) throws -> URL {
        let fm = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true {
            throw EPUBError.unsafePath
        }
        guard rootValues.isDirectory == true else {
            throw EPUBError.invalidPackage
        }
        var url = root
        let segments = canonicalPath.split(separator: "/")
        for segment in segments.dropLast() {
            url.appendPathComponent(String(segment))
            guard fm.fileExists(atPath: url.path) else {
                throw EPUBError.invalidPackage
            }
            let dirValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if dirValues.isSymbolicLink == true {
                throw EPUBError.unsafePath
            }
            guard dirValues.isDirectory == true else {
                throw EPUBError.invalidPackage
            }
        }
        guard let leaf = segments.last else {
            throw EPUBError.unsafePath
        }
        url.appendPathComponent(String(leaf))
        guard fm.fileExists(atPath: url.path) else {
            throw EPUBError.invalidPackage
        }
        return url
    }

    private static func uint16BE(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    static func decodeStrictCSSString(_ data: Data) -> String? {
        if data.count >= 4 {
            let b0 = data[data.startIndex]
            let b1 = data[data.startIndex + 1]
            let b2 = data[data.startIndex + 2]
            let b3 = data[data.startIndex + 3]
            if (b0 == 0xFF && b1 == 0xFE && b2 == 0x00 && b3 == 0x00) ||
                (b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF) {
                return nil
            }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return decodeStrictUTF8(data.dropFirst(3))
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return decodeStrictUTF16(data.dropFirst(2), bigEndian: true)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return decodeStrictUTF16(data.dropFirst(2), bigEndian: false)
        }
        return decodeStrictUTF8(data[...])
    }

    private static func decodeStrictUTF8(_ slice: Data.SubSequence) -> String? {
        var decoder = UTF8()
        var iterator = slice.makeIterator()
        var out = ""
        out.reserveCapacity(slice.count)
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                if scalar.value == 0 { return nil }
                out.unicodeScalars.append(scalar)
            case .emptyInput:
                return out
            case .error:
                return nil
            }
        }
    }

    private static func decodeStrictUTF16(_ slice: Data.SubSequence, bigEndian: Bool) -> String? {
        guard slice.count >= 2, slice.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(slice.count / 2)
        var index = slice.startIndex
        while index < slice.endIndex {
            let first = UInt16(slice[index])
            let second = UInt16(slice[index + 1])
            let unit = bigEndian ? ((first << 8) | second) : (first | (second << 8))
            if unit == 0 { return nil }
            units.append(unit)
            index += 2
        }
        var decoder = UTF16()
        var iterator = units.makeIterator()
        var out = ""
        out.reserveCapacity(units.count)
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                if scalar.value == 0 { return nil }
                out.unicodeScalars.append(scalar)
            case .emptyInput:
                return out
            case .error:
                return nil
            }
        }
    }

    /// Validates and normalizes author `class` attribute tokens, stripping reserved `yj-*` names.
    public static func sanitizeClassAttribute(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for tokenSlice in raw.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(tokenSlice).precomposedStringWithCanonicalMapping
            guard isValidAuthorClassToken(token) else { continue }
            if seen.insert(token).inserted {
                result.append(token)
            }
        }
        return result
    }

    static func isValidAuthorClassToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 128 else { return false }
        let lower = token.lowercased()
        if lower.hasPrefix("yj-") || lower.hasPrefix("data-yj-") {
            return false
        }
        let scalars = Array(token.unicodeScalars)
        guard let first = scalars.first else { return false }
        var index = 0
        if first.value == 0x2D { // '-'
            guard scalars.count >= 2 else { return false }
            let second = scalars[1]
            guard isIdentStart(second) else { return false }
            index = 2
        } else {
            guard isIdentStart(first) else { return false }
            index = 1
        }
        while index < scalars.count {
            guard isIdentChar(scalars[index]) else { return false }
            index += 1
        }
        return true
    }

    private static func isIdentStart(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F { // A-Z a-z _
            return true
        }
        return v >= 0x80 && !(v >= 0xD800 && v <= 0xDFFF)
    }

    private static func isIdentChar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if isIdentStart(scalar) || (v >= 0x30 && v <= 0x39) || v == 0x2D { // 0-9 -
            return true
        }
        return false
    }

    // MARK: - Chapter Style Accumulator

    final class ValidationCache {
        var verifiedFonts: [String: String] = [:]
        var cssSources: [String: String] = [:]
    }

    final class ChapterCollector {
        let documentPath: String
        let scopeID: String
        let manifestByPath: [String: String]
        let destination: URL
        let cache: ValidationCache?

        private var fontFaces: [ParsedFontFace] = []
        private var styleRules: [ParsedStyleRule] = []
        private var inlineRules: [ParsedInlineRule] = []
        private var inlineKeyToClass: [InlineRuleKey: String] = [:]
        private var fontFamilyMap: [String: String] = [:]
        private var fontFamilyOrder: [String] = []
        private(set) var referencedFonts: [String: String] = [:]
        private var totalRawCSSBytes = 0
        private var linkCount = 0

        init(
            documentPath: String,
            scopeID: String,
            manifestByPath: [String: String],
            destination: URL,
            cache: ValidationCache? = nil
        ) {
            self.documentPath = documentPath
            self.scopeID = scopeID
            self.manifestByPath = manifestByPath
            self.destination = destination
            self.cache = cache
        }

        func addExternalStylesheet(href: String, emitRules: Bool = true) throws {
            linkCount += 1
            guard linkCount <= 64 else {
                throw EPUBError.limitExceeded
            }
            let resolved = try EPUBResourcePath.resolve(href, relativeTo: documentPath)
            guard resolved.fragment == nil,
                  let mediaType = manifestByPath[resolved.path] else {
                throw EPUBError.invalidPackage
            }
            guard mediaType.lowercased() == "text/css" else {
                throw EPUBError.unsupportedContent
            }
            let cssText: String
            if let cached = cache?.cssSources[resolved.path] {
                cssText = cached
            } else {
                cssText = try EPUBAuthorStyles.readExtractedCSS(at: resolved.path, under: destination)
                cache?.cssSources[resolved.path] = cssText
            }
            try addStylesheet(cssText, sourcePath: resolved.path, maxSingleBytes: maxExternalCSSBytes, emitRules: emitRules)
        }

        func addInlineBlockStylesheet(_ cssText: String, emitRules: Bool = true) throws {
            try addStylesheet(cssText, sourcePath: documentPath, maxSingleBytes: maxExternalCSSBytes, emitRules: emitRules)
        }
        func auditInlineStyleAttribute(_ styleText: String) throws {
            let utf8Count = styleText.utf8.count
            guard utf8Count <= maxInlineCSSBytes else {
                throw EPUBError.limitExceeded
            }
            let tokens = try CSSTokenizer.tokenize(styleText)
            for token in tokens {
                if case .atKeyword = token {
                    throw EPUBError.unsupportedContent
                }
            }
            let context = SanitizationContext(
                collector: self,
                cssSourcePath: documentPath
            )
            try context.auditRawTokens(tokens)
        }

        func addInlineStyleAttribute(_ styleText: String, isBody: Bool) throws -> String? {
            let utf8Count = styleText.utf8.count
            guard utf8Count <= maxInlineCSSBytes else {
                throw EPUBError.limitExceeded
            }
            totalRawCSSBytes += utf8Count
            guard totalRawCSSBytes <= maxTotalChapterCSSBytes else {
                throw EPUBError.limitExceeded
            }
            let tokens = try CSSTokenizer.tokenize(styleText)
            for token in tokens {
                if case .atKeyword = token {
                    throw EPUBError.unsupportedContent
                }
            }
            let declarations = try CSSParser.parseDeclarationList(tokens)
            let context = SanitizationContext(
                collector: self,
                cssSourcePath: documentPath
            )
            let sanitizedDecls = try context.sanitizeDeclarations(declarations, isRootScope: isBody)
            guard !sanitizedDecls.isEmpty else {
                return nil
            }
            let key = InlineRuleKey(isBody: isBody, declarations: sanitizedDecls)
            if let existing = inlineKeyToClass[key] {
                return existing
            }
            guard inlineRules.count < 4096 else {
                throw EPUBError.limitExceeded
            }
            let className = "yj-i-\(inlineRules.count)"
            inlineKeyToClass[key] = className
            inlineRules.append(ParsedInlineRule(className: className, isBody: isBody, declarations: sanitizedDecls))
            return className
        }

        private func addStylesheet(_ cssText: String, sourcePath: String, maxSingleBytes: Int, emitRules: Bool = true) throws {
            let utf8Count = cssText.utf8.count
            guard utf8Count <= maxSingleBytes else {
                throw EPUBError.limitExceeded
            }
            totalRawCSSBytes += utf8Count
            guard totalRawCSSBytes <= maxTotalChapterCSSBytes else {
                throw EPUBError.limitExceeded
            }
            let tokens = try CSSTokenizer.tokenize(cssText)
            let items = try CSSParser.parseStylesheet(tokens)
            let context = SanitizationContext(
                collector: self,
                cssSourcePath: sourcePath
            )
            for item in items {
                switch item {
                case .atRule(let name, let prelude, let block):
                    let lowerName = name.lowercased()
                    if lowerName == "import" {
                        throw EPUBError.unsupportedContent
                    } else if lowerName == "charset" {
                        try context.validateCharsetRule(prelude: prelude, block: block)
                    } else if lowerName == "font-face" {
                        guard let block else { throw EPUBError.unsupportedContent }
                        let face = try context.parseFontFace(blockTokens: block)
                        let key = face.familyKey
                        if emitRules {
                            if fontFamilyMap[key] == nil {
                                let scoped = "yjfont-\(scopeID)-\(fontFamilyOrder.count)"
                                fontFamilyMap[key] = scoped
                                fontFamilyOrder.append(key)
                            }
                            fontFaces.append(face)
                        }
                    } else {
                        try context.auditRawTokens(prelude)
                        if let block {
                            try context.auditRawTokens(block)
                        }
                    }
                case .qualifiedRule(let prelude, let declarations):
                    try context.auditDeclarations(declarations)
                    let selectors = CSSSelectorParser.parseSelectorList(prelude)
                    let isRootRule = selectors.contains { $0.isRootOnly }
                    let sanitizedDecls = try context.sanitizeDeclarations(declarations, isRootScope: isRootRule)
                    guard emitRules, !selectors.isEmpty, !sanitizedDecls.isEmpty else {
                        continue
                    }
                    guard styleRules.count < 10_000 else {
                        throw EPUBError.limitExceeded
                    }
                    styleRules.append(ParsedStyleRule(selectors: selectors, declarations: sanitizedDecls))
                }
            }
        }

        func renderCSS(bodyClasses: Set<String> = [], bodyID: String? = nil) throws -> String {
            var chunks: [String] = []
            for face in fontFaces {
                guard let scopedFamily = fontFamilyMap[face.familyKey] else { continue }
                chunks.append(face.render(scopedFamilyName: scopedFamily))
            }
            for rule in styleRules {
                let scopedSelectors = rule.selectors.flatMap {
                    $0.renderScoped(scopeID: scopeID, bodyClasses: bodyClasses, bodyID: bodyID)
                }
                guard !scopedSelectors.isEmpty else { continue }
                let declText = rule.declarations.map { $0.render(fontFamilyMap: fontFamilyMap) }.joined(separator: "; ")
                chunks.append("\(scopedSelectors.joined(separator: ", ")) { \(declText); }")
            }
            // A normal inline declaration outranks every retained author selector.
            // The contradictory IDs never match any element; no reserved DOM ID is assumed.
            let maximumIDs = styleRules.flatMap(\.selectors).map {
                $0.head.ids.count + $0.rest.reduce(0) { $0 + $1.compound.ids.count }
            }.max() ?? 0
            let inlinePriority = String(repeating: ":not(#yj-inline-a#yj-inline-b)", count: maximumIDs / 2 + 1)
            for inlineRule in inlineRules {
                let selector: String
                if inlineRule.isBody {
                    selector = "html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(scopeID)\"].\(inlineRule.className)\(inlinePriority)"
                } else {
                    selector = "html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(scopeID)\"] .\(inlineRule.className)\(inlinePriority)"
                }
                let declText = inlineRule.declarations.map { $0.render(fontFamilyMap: fontFamilyMap) }.joined(separator: "; ")
                chunks.append("\(selector) { \(declText); }")
            }
            let rendered = chunks.joined(separator: "\n")
            guard rendered.utf8.count <= maxTotalChapterCSSBytes else {
                throw EPUBError.limitExceeded
            }
            return rendered
        }

        func recordReferencedFont(path: String, mediaType: String) throws {
            if let previous = referencedFonts[path], previous != mediaType {
                throw EPUBError.corruptResource
            }
            referencedFonts[path] = mediaType
        }
    }
    /// Standalone helper for testing or sanitizing a single CSS stylesheet against a canonical source path.
    public static func sanitizeStylesheet(
        _ cssText: String,
        sourcePath: String,
        documentPath: String? = nil,
        manifestByPath: [String: String],
        destination: URL
    ) throws -> (css: String, referencedFonts: [String: String]) {
        let canonicalSource = try EPUBResourcePath.canonical(sourcePath)
        let canonicalDoc = try EPUBResourcePath.canonical(documentPath ?? sourcePath)
        let scope = scopeIdentifier(for: canonicalDoc)
        let collector = ChapterCollector(
            documentPath: canonicalDoc,
            scopeID: scope,
            manifestByPath: manifestByPath,
            destination: destination
        )
        try collector.addStylesheet(cssText, sourcePath: canonicalSource, maxSingleBytes: maxExternalCSSBytes)
        return (try collector.renderCSS(), collector.referencedFonts)
    }

    // MARK: - CSS Tokens

    enum CSSToken: Equatable {
        case ident(String)
        case function(String)
        case atKeyword(String)
        case hash(String, isID: Bool)
        case string(String)
        case badString
        case url(String)
        case badUrl
        case number(value: Double, raw: String, isInteger: Bool)
        case percentage(value: Double, raw: String)
        case dimension(value: Double, raw: String, unit: String)
        case delim(UInt32)
        case whitespace
        case colon
        case semicolon
        case comma
        case lbrace
        case rbrace
        case lparen
        case rparen
        case lbracket
        case rbracket
        case cdo
        case cdc
    }

    enum CSSTokenizer {
        private static let maxTokenCount = 200_000

        static func tokenize(_ rawInput: String) throws -> [CSSToken] {
            // Preprocess per CSS Syntax Level 3 §3.3
            var scalars: [Unicode.Scalar] = []
            scalars.reserveCapacity(rawInput.unicodeScalars.count)
            var pendingCR = false
            for scalar in rawInput.unicodeScalars {
                let v = scalar.value
                if v == 0 {
                    throw EPUBError.unsupportedContent
                }
                if pendingCR {
                    pendingCR = false
                    if v == 0x0A {
                        continue
                    }
                }
                if v == 0x0D {
                    pendingCR = true
                    scalars.append(Unicode.Scalar(0x0A)!)
                } else if v == 0x0C {
                    scalars.append(Unicode.Scalar(0x0A)!)
                } else {
                    scalars.append(scalar)
                }
            }

            var tokens: [CSSToken] = []
            var index = 0
            let count = scalars.count

            func push(_ token: CSSToken) throws {
                if tokens.count >= maxTokenCount {
                    throw EPUBError.limitExceeded
                }
                tokens.append(token)
            }

            while index < count {
                let ch = scalars[index].value

                // Comments
                if ch == 0x2F, index + 1 < count, scalars[index + 1].value == 0x2A { // /*
                    index += 2
                    while index < count {
                        if scalars[index].value == 0x2A, index + 1 < count, scalars[index + 1].value == 0x2F {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }

                // Whitespace
                if isCSSWhitespace(ch) {
                    while index < count, isCSSWhitespace(scalars[index].value) {
                        index += 1
                    }
                    try push(.whitespace)
                    continue
                }

                // Strings
                if ch == 0x22 || ch == 0x27 { // " or '
                    let token = consumeString(scalars: scalars, index: &index, quote: ch)
                    if case .badString = token {
                        throw EPUBError.unsupportedContent
                    }
                    try push(token)
                    continue
                }

                // Hash
                if ch == 0x23 { // #
                    index += 1
                    if index < count, (isNameChar(scalars[index].value) || startsValidEscape(scalars, at: index)) {
                        let isID = startsIdentifier(scalars, at: index)
                        let name = consumeName(scalars: scalars, index: &index)
                        try push(.hash(name, isID: isID))
                    } else {
                        try push(.delim(0x23))
                    }
                    continue
                }

                // Punctuation
                switch ch {
                case 0x28: index += 1; try push(.lparen); continue
                case 0x29: index += 1; try push(.rparen); continue
                case 0x2C: index += 1; try push(.comma); continue
                case 0x3A: index += 1; try push(.colon); continue
                case 0x3B: index += 1; try push(.semicolon); continue
                case 0x5B: index += 1; try push(.lbracket); continue
                case 0x5D: index += 1; try push(.rbracket); continue
                case 0x7B: index += 1; try push(.lbrace); continue
                case 0x7D: index += 1; try push(.rbrace); continue
                default: break
                }

                // CDO <!--
                if ch == 0x3C, index + 3 < count,
                   scalars[index + 1].value == 0x21,
                   scalars[index + 2].value == 0x2D,
                   scalars[index + 3].value == 0x2D {
                    index += 4
                    try push(.cdo)
                    continue
                }

                // CDC --> or number starting with '-' or ident starting with '-'
                if ch == 0x2D { // -
                    if startsNumber(scalars, at: index) {
                        try push(consumeNumeric(scalars: scalars, index: &index))
                        continue
                    }
                    if index + 2 < count, scalars[index + 1].value == 0x2D, scalars[index + 2].value == 0x3E {
                        index += 3
                        try push(.cdc)
                        continue
                    }
                    if startsIdentifier(scalars, at: index) {
                        try push(try consumeIdentLike(scalars: scalars, index: &index))
                        continue
                    }
                    index += 1
                    try push(.delim(0x2D))
                    continue
                }

                // + or .
                if ch == 0x2B || ch == 0x2E {
                    if startsNumber(scalars, at: index) {
                        try push(consumeNumeric(scalars: scalars, index: &index))
                    } else {
                        index += 1
                        try push(.delim(ch))
                    }
                    continue
                }

                // Digits
                if isDigit(ch) {
                    try push(consumeNumeric(scalars: scalars, index: &index))
                    continue
                }

                // @keyword
                if ch == 0x40 { // @
                    index += 1
                    if startsIdentifier(scalars, at: index) {
                        let name = consumeName(scalars: scalars, index: &index)
                        try push(.atKeyword(name))
                    } else {
                        try push(.delim(0x40))
                    }
                    continue
                }

                // Escape starting an identifier
                if ch == 0x5C { // \
                    if startsValidEscape(scalars, at: index) {
                        try push(try consumeIdentLike(scalars: scalars, index: &index))
                    } else {
                        index += 1
                        try push(.delim(0x5C))
                    }
                    continue
                }

                // Ident-start
                if isNameStart(ch) {
                    try push(try consumeIdentLike(scalars: scalars, index: &index))
                    continue
                }

                // Any other delimiter
                index += 1
                try push(.delim(ch))
            }

            return tokens
        }

        private static func isCSSWhitespace(_ v: UInt32) -> Bool {
            v == 0x20 || v == 0x09 || v == 0x0A
        }

        private static func isDigit(_ v: UInt32) -> Bool {
            v >= 0x30 && v <= 0x39
        }

        private static func isHexDigit(_ v: UInt32) -> Bool {
            (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x46) || (v >= 0x61 && v <= 0x66)
        }

        private static func hexDigitValue(_ v: UInt32) -> UInt32 {
            if v >= 0x30 && v <= 0x39 { return v - 0x30 }
            if v >= 0x41 && v <= 0x46 { return v - 0x41 + 10 }
            return v - 0x61 + 10
        }

        private static func isNameStart(_ v: UInt32) -> Bool {
            (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F || v >= 0x80
        }

        private static func isNameChar(_ v: UInt32) -> Bool {
            isNameStart(v) || isDigit(v) || v == 0x2D
        }

        private static func startsValidEscape(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
            guard index < scalars.count, scalars[index].value == 0x5C else { return false }
            if index + 1 >= scalars.count { return false }
            return scalars[index + 1].value != 0x0A
        }

        private static func startsIdentifier(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
            guard index < scalars.count else { return false }
            let first = scalars[index].value
            if first == 0x2D {
                guard index + 1 < scalars.count else { return false }
                let second = scalars[index + 1].value
                return isNameStart(second) || second == 0x2D || startsValidEscape(scalars, at: index + 1)
            }
            if isNameStart(first) {
                return true
            }
            if first == 0x5C {
                return startsValidEscape(scalars, at: index)
            }
            return false
        }

        private static func startsNumber(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
            guard index < scalars.count else { return false }
            let first = scalars[index].value
            if first == 0x2B || first == 0x2D {
                guard index + 1 < scalars.count else { return false }
                let second = scalars[index + 1].value
                if isDigit(second) { return true }
                if second == 0x2E, index + 2 < scalars.count, isDigit(scalars[index + 2].value) { return true }
                return false
            }
            if first == 0x2E {
                return index + 1 < scalars.count && isDigit(scalars[index + 1].value)
            }
            return isDigit(first)
        }

        private static func consumeEscape(scalars: [Unicode.Scalar], index: inout Int) -> Unicode.Scalar {
            // Current index points right after '\'
            guard index < scalars.count else {
                return Unicode.Scalar(0xFFFD)!
            }
            let first = scalars[index].value
            if isHexDigit(first) {
                var value: UInt32 = 0
                var digits = 0
                while index < scalars.count, digits < 6, isHexDigit(scalars[index].value) {
                    value = (value << 4) | hexDigitValue(scalars[index].value)
                    index += 1
                    digits += 1
                }
                if index < scalars.count, isCSSWhitespace(scalars[index].value) {
                    index += 1
                }
                if value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) {
                    return Unicode.Scalar(0xFFFD)!
                }
                return Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!
            }
            index += 1
            return Unicode.Scalar(first) ?? Unicode.Scalar(0xFFFD)!
        }

        private static func consumeName(scalars: [Unicode.Scalar], index: inout Int) -> String {
            var out = ""
            while index < scalars.count {
                let v = scalars[index].value
                if isNameChar(v) {
                    out.unicodeScalars.append(scalars[index])
                    index += 1
                } else if startsValidEscape(scalars, at: index) {
                    index += 1
                    out.unicodeScalars.append(consumeEscape(scalars: scalars, index: &index))
                } else {
                    break
                }
            }
            return out
        }

        private static func consumeString(scalars: [Unicode.Scalar], index: inout Int, quote: UInt32) -> CSSToken {
            index += 1
            var out = ""
            while index < scalars.count {
                let v = scalars[index].value
                if v == quote {
                    index += 1
                    return .string(out)
                }
                if v == 0x0A {
                    return .badString
                }
                if v == 0x5C {
                    if index + 1 >= scalars.count {
                        return .badString
                    }
                    if scalars[index + 1].value == 0x0A {
                        index += 2
                        continue
                    }
                    index += 1
                    out.unicodeScalars.append(consumeEscape(scalars: scalars, index: &index))
                    continue
                }
                out.unicodeScalars.append(scalars[index])
                index += 1
            }
            return .badString
        }

        private static func consumeNumeric(scalars: [Unicode.Scalar], index: inout Int) -> CSSToken {
            var raw = ""
            var isInteger = true
            if index < scalars.count, (scalars[index].value == 0x2B || scalars[index].value == 0x2D) {
                raw.unicodeScalars.append(scalars[index])
                index += 1
            }
            while index < scalars.count, isDigit(scalars[index].value) {
                raw.unicodeScalars.append(scalars[index])
                index += 1
            }
            if index + 1 < scalars.count, scalars[index].value == 0x2E, isDigit(scalars[index + 1].value) {
                isInteger = false
                raw.append(".")
                index += 1
                while index < scalars.count, isDigit(scalars[index].value) {
                    raw.unicodeScalars.append(scalars[index])
                    index += 1
                }
            }
            if index + 1 < scalars.count, (scalars[index].value == 0x65 || scalars[index].value == 0x45) {
                let next = scalars[index + 1].value
                if isDigit(next) || ((next == 0x2B || next == 0x2D) && index + 2 < scalars.count && isDigit(scalars[index + 2].value)) {
                    isInteger = false
                    raw.unicodeScalars.append(scalars[index])
                    index += 1
                    if scalars[index].value == 0x2B || scalars[index].value == 0x2D {
                        raw.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    while index < scalars.count, isDigit(scalars[index].value) {
                        raw.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                }
            }

            let numericValue = Double(raw) ?? Double.nan
            if index < scalars.count, startsIdentifier(scalars, at: index) {
                let unit = consumeName(scalars: scalars, index: &index)
                return .dimension(value: numericValue, raw: raw, unit: unit)
            }
            if index < scalars.count, scalars[index].value == 0x25 {
                index += 1
                return .percentage(value: numericValue, raw: raw)
            }
            return .number(value: numericValue, raw: raw, isInteger: isInteger)
        }

        private static func consumeIdentLike(scalars: [Unicode.Scalar], index: inout Int) throws -> CSSToken {
            let name = consumeName(scalars: scalars, index: &index)
            if name.lowercased() == "url", index < scalars.count, scalars[index].value == 0x28 { // (
                index += 1
                var peek = index
                while peek < scalars.count, isCSSWhitespace(scalars[peek].value) {
                    peek += 1
                }
                if peek < scalars.count, (scalars[peek].value == 0x22 || scalars[peek].value == 0x27) {
                    return .function(name)
                }
                let urlToken = consumeUnquotedURL(scalars: scalars, index: &index)
                if case .badUrl = urlToken {
                    throw EPUBError.unsupportedContent
                }
                return urlToken
            }
            if index < scalars.count, scalars[index].value == 0x28 {
                index += 1
                return .function(name)
            }
            return .ident(name)
        }

        private static func consumeUnquotedURL(scalars: [Unicode.Scalar], index: inout Int) -> CSSToken {
            while index < scalars.count, isCSSWhitespace(scalars[index].value) {
                index += 1
            }
            var out = ""
            while index < scalars.count {
                let v = scalars[index].value
                if v == 0x29 { // )
                    index += 1
                    return .url(out)
                }
                if isCSSWhitespace(v) {
                    while index < scalars.count, isCSSWhitespace(scalars[index].value) {
                        index += 1
                    }
                    if index < scalars.count, scalars[index].value == 0x29 {
                        index += 1
                        return .url(out)
                    }
                    return .badUrl
                }
                if v == 0x22 || v == 0x27 || v == 0x28 || v <= 0x1F || v == 0x7F {
                    return .badUrl
                }
                if v == 0x5C {
                    guard startsValidEscape(scalars, at: index) else {
                        return .badUrl
                    }
                    index += 1
                    out.unicodeScalars.append(consumeEscape(scalars: scalars, index: &index))
                    continue
                }
                out.unicodeScalars.append(scalars[index])
                index += 1
            }
            return .badUrl
        }
    }

    // MARK: - CSS AST & Parser

    enum CSSItem {
        case atRule(name: String, prelude: [CSSToken], block: [CSSToken]?)
        case qualifiedRule(prelude: [CSSToken], declarations: [CSSDeclaration])
    }

    struct CSSDeclaration {
        let name: String
        let valueTokens: [CSSToken]
        let important: Bool
    }

    enum CSSParser {
        private static let maxNestingDepth = 32

        static func parseStylesheet(_ tokens: [CSSToken]) throws -> [CSSItem] {
            var items: [CSSItem] = []
            var index = 0
            while index < tokens.count {
                switch tokens[index] {
                case .whitespace, .cdo, .cdc, .semicolon:
                    index += 1
                case .atKeyword(let name):
                    index += 1
                    let (prelude, block) = try consumeAtRule(tokens: tokens, index: &index)
                    items.append(.atRule(name: name, prelude: prelude, block: block))
                default:
                    if let rule = try consumeQualifiedRule(tokens: tokens, index: &index) {
                        items.append(rule)
                    }
                }
            }
            return items
        }

        private static func consumeAtRule(tokens: [CSSToken], index: inout Int) throws -> (prelude: [CSSToken], block: [CSSToken]?) {
            var prelude: [CSSToken] = []
            while index < tokens.count {
                switch tokens[index] {
                case .semicolon:
                    index += 1
                    return (prelude, nil)
                case .lbrace:
                    let block = try consumeBlockContent(tokens: tokens, index: &index, open: .lbrace, close: .rbrace, depth: 0)
                    return (prelude, block)
                default:
                    prelude.append(contentsOf: try consumeComponentValue(tokens: tokens, index: &index, depth: 0))
                }
            }
            return (prelude, nil)
        }

        private static func consumeQualifiedRule(tokens: [CSSToken], index: inout Int) throws -> CSSItem? {
            var prelude: [CSSToken] = []
            while index < tokens.count {
                switch tokens[index] {
                case .lbrace:
                    let block = try consumeBlockContent(tokens: tokens, index: &index, open: .lbrace, close: .rbrace, depth: 0)
                    let declarations = try parseDeclarationList(block)
                    return .qualifiedRule(prelude: prelude, declarations: declarations)
                case .rbrace:
                    index += 1
                    return nil
                default:
                    prelude.append(contentsOf: try consumeComponentValue(tokens: tokens, index: &index, depth: 0))
                }
            }
            return nil
        }

        private static func consumeComponentValue(tokens: [CSSToken], index: inout Int, depth: Int) throws -> [CSSToken] {
            guard depth < maxNestingDepth else {
                throw EPUBError.limitExceeded
            }
            let current = tokens[index]
            switch current {
            case .lbrace:
                var result: [CSSToken] = [.lbrace]
                result.append(contentsOf: try consumeBlockContent(tokens: tokens, index: &index, open: .lbrace, close: .rbrace, depth: depth + 1))
                result.append(.rbrace)
                return result
            case .lparen:
                var result: [CSSToken] = [.lparen]
                result.append(contentsOf: try consumeBlockContent(tokens: tokens, index: &index, open: .lparen, close: .rparen, depth: depth + 1))
                result.append(.rparen)
                return result
            case .lbracket:
                var result: [CSSToken] = [.lbracket]
                result.append(contentsOf: try consumeBlockContent(tokens: tokens, index: &index, open: .lbracket, close: .rbracket, depth: depth + 1))
                result.append(.rbracket)
                return result
            case .function:
                var result: [CSSToken] = [current]
                index += 1
                while index < tokens.count {
                    if case .rparen = tokens[index] {
                        index += 1
                        result.append(.rparen)
                        return result
                    }
                    result.append(contentsOf: try consumeComponentValue(tokens: tokens, index: &index, depth: depth + 1))
                }
                result.append(.rparen)
                return result
            default:
                index += 1
                return [current]
            }
        }

        private static func consumeBlockContent(
            tokens: [CSSToken],
            index: inout Int,
            open: CSSToken,
            close: CSSToken,
            depth: Int
        ) throws -> [CSSToken] {
            guard depth < maxNestingDepth else {
                throw EPUBError.limitExceeded
            }
            index += 1 // consume opening token
            var content: [CSSToken] = []
            while index < tokens.count {
                if tokens[index] == close {
                    index += 1
                    return content
                }
                content.append(contentsOf: try consumeComponentValue(tokens: tokens, index: &index, depth: depth + 1))
            }
            return content
        }

        static func parseDeclarationList(_ tokens: [CSSToken]) throws -> [CSSDeclaration] {
            var declarations: [CSSDeclaration] = []
            var cursor = 0
            while cursor < tokens.count {
                // Split by ';' at depth 0
                var slice: [CSSToken] = []
                var parenDepth = 0
                var bracketDepth = 0
                var braceDepth = 0
                while cursor < tokens.count {
                    let tok = tokens[cursor]
                    cursor += 1
                    switch tok {
                    case .lparen, .function: parenDepth += 1
                    case .rparen: parenDepth = max(0, parenDepth - 1)
                    case .lbracket: bracketDepth += 1
                    case .rbracket: bracketDepth = max(0, bracketDepth - 1)
                    case .lbrace: braceDepth += 1
                    case .rbrace: braceDepth = max(0, braceDepth - 1)
                    case .semicolon where parenDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                        break
                    default:
                        slice.append(tok)
                        continue
                    }
                    if case .semicolon = tok, parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 {
                        break
                    }
                    slice.append(tok)
                }

                let trimmed = trimWhitespace(slice)
                guard !trimmed.isEmpty else { continue }
                guard declarations.count < 256 else {
                    throw EPUBError.limitExceeded
                }

                guard case .ident(let propName) = trimmed[0] else {
                    // Preserve malicious url/expression detection even in malformed declarations.
                    if let decl = extractMaliciousScanDecl(trimmed) {
                        declarations.append(decl)
                    }
                    continue
                }
                var idx = 1
                while idx < trimmed.count, case .whitespace = trimmed[idx] { idx += 1 }
                guard idx < trimmed.count, case .colon = trimmed[idx] else {
                    if let decl = extractMaliciousScanDecl(trimmed) {
                        declarations.append(decl)
                    }
                    continue
                }
                idx += 1
                var valueTokens = trimWhitespace(Array(trimmed[idx...]))
                var important = false
                if valueTokens.count >= 2,
                   case .delim(0x21) = valueTokens[valueTokens.count - 2],
                   case .ident(let imp) = valueTokens[valueTokens.count - 1],
                   imp.lowercased() == "important" {
                    important = true
                    valueTokens = trimWhitespace(Array(valueTokens.dropLast(2)))
                } else if valueTokens.count >= 3,
                          case .delim(0x21) = valueTokens[valueTokens.count - 3],
                          case .whitespace = valueTokens[valueTokens.count - 2],
                          case .ident(let imp) = valueTokens[valueTokens.count - 1],
                          imp.lowercased() == "important" {
                    important = true
                    valueTokens = trimWhitespace(Array(valueTokens.dropLast(3)))
                }
                declarations.append(CSSDeclaration(name: propName, valueTokens: valueTokens, important: important))
            }
            return declarations
        }

        private static func extractMaliciousScanDecl(_ tokens: [CSSToken]) -> CSSDeclaration? {
            CSSDeclaration(name: "", valueTokens: tokens, important: false)
        }

        static func trimWhitespace(_ tokens: [CSSToken]) -> [CSSToken] {
            var start = 0
            while start < tokens.count, case .whitespace = tokens[start] { start += 1 }
            var end = tokens.count
            while end > start, case .whitespace = tokens[end - 1] { end -= 1 }
            return Array(tokens[start..<end])
        }
    }

    // MARK: - Selectors

    enum CSSCombinator {
        case descendant
        case child
    }

    struct CSSCompoundSelector {
        var tag: String?
        var classes: [String]
        var ids: [String]
    }

    struct CSSComplexSelector {
        let head: CSSCompoundSelector
        let rest: [(combinator: CSSCombinator, compound: CSSCompoundSelector)]

        var isRootOnly: Bool {
            rest.isEmpty && (head.tag == "html" || head.tag == "body")
        }

        func renderScoped(scopeID: String, bodyClasses: Set<String>, bodyID: String?) -> [String] {
            let scopeBase = "html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(scopeID)\"]"

            // Map html / body root rules directly onto the chapter scope element.
            if head.tag == "html" || head.tag == "body" {
                if head.tag == "html", (!head.classes.isEmpty || !head.ids.isEmpty) {
                    return []
                }
                var rootSuffix = ""
                for cls in head.classes {
                    rootSuffix += "." + escapeCSSIdentifier(cls)
                }
                for id in head.ids {
                    rootSuffix += renderOriginalID(id)
                }

                var startIdx = 0
                if head.tag == "html",
                   let first = rest.first,
                   first.compound.tag == "body" {
                    for cls in first.compound.classes {
                        rootSuffix += "." + escapeCSSIdentifier(cls)
                    }
                    for id in first.compound.ids {
                        rootSuffix += renderOriginalID(id)
                    }
                    startIdx = 1
                }

                var rendered = scopeBase + rootSuffix
                for step in rest.dropFirst(startIdx) {
                    if step.compound.tag == "html" || step.compound.tag == "body" {
                        return []
                    }
                    rendered += step.combinator == .child ? " > " : " "
                    rendered += renderCompound(step.compound)
                }
                return [rendered]
            }

            // Reject html/body occurring below the root.
            for step in rest where step.compound.tag == "html" || step.compound.tag == "body" {
                return []
            }

            // Normal descendant selector inside chapter scope.
            var desc = scopeBase + " " + renderCompound(head)
            for step in rest {
                desc += step.combinator == .child ? " > " : " "
                desc += renderCompound(step.compound)
            }

            // If head has no tag and targets class/id that is also on <body>, allow matching the scope root too.
            if head.tag == nil, !head.classes.isEmpty || !head.ids.isEmpty {
                let matchesBodyID = head.ids.allSatisfy { $0 == bodyID }
                let matchesBodyClasses = head.classes.allSatisfy { bodyClasses.contains($0) }
                if matchesBodyID && matchesBodyClasses {
                    var rootMatches = scopeBase
                    for cls in head.classes {
                        rootMatches += "." + escapeCSSIdentifier(cls)
                    }
                    for id in head.ids {
                        rootMatches += renderOriginalID(id)
                    }
                    for step in rest {
                        rootMatches += step.combinator == .child ? " > " : " "
                        rootMatches += renderCompound(step.compound)
                    }
                    return [desc, rootMatches]
                }
            }

            return [desc]
        }

        private func renderOriginalID(_ id: String) -> String {
            // :is preserves ID specificity while the impossible branch cannot broaden matching.
            ":is([data-yj-original-id=\"\(escapeCSSString(id))\"], #yj-id-specificity:not(*))"
        }

        private func renderCompound(_ compound: CSSCompoundSelector) -> String {
            var out = ""
            if let tag = compound.tag {
                if tag == "span" {
                    out += "span:where(:not([id^=\"yj-t\"]):not([data-yj-original-id^=\"yj-t\"]))"
                } else {
                    out += tag
                }
            }
            for cls in compound.classes {
                out += "." + escapeCSSIdentifier(cls)
            }
            for id in compound.ids {
                out += renderOriginalID(id)
            }
            return out
        }
    }

    enum CSSSelectorParser {
        private static let allowedTags: Set<String> = [
            "html", "body",
            "article", "section", "nav", "aside", "header", "footer", "main", "div", "address",
            "h1", "h2", "h3", "h4", "h5", "h6", "hgroup",
            "p", "blockquote", "pre", "hr", "br", "wbr", "figure", "figcaption", "details", "summary",
            "ul", "ol", "li", "dl", "dt", "dd",
            "span", "a", "em", "strong", "i", "b", "u", "s", "small", "sub", "sup", "mark",
            "q", "cite", "code", "kbd", "samp", "var", "dfn", "abbr", "time", "bdi", "bdo",
            "ruby", "rt", "rp", "del", "ins",
            "table", "caption", "thead", "tbody", "tfoot", "tr", "th", "td", "colgroup", "col",
            "img"
        ]

        static func parseSelectorList(_ tokens: [CSSToken]) -> [CSSComplexSelector] {
            var groups: [[CSSToken]] = []
            var current: [CSSToken] = []
            var depth = 0
            for token in tokens {
                switch token {
                case .lparen, .lbracket, .lbrace, .function:
                    depth += 1
                    current.append(token)
                case .rparen, .rbracket, .rbrace:
                    depth = max(0, depth - 1)
                    current.append(token)
                case .comma where depth == 0:
                    groups.append(current)
                    current = []
                default:
                    current.append(token)
                }
            }
            groups.append(current)
            guard groups.count <= 32 else { return [] }

            var parsed: [CSSComplexSelector] = []
            for group in groups {
                if let complex = parseComplexSelector(group) {
                    parsed.append(complex)
                }
            }
            return parsed
        }

        private static func parseComplexSelector(_ rawTokens: [CSSToken]) -> CSSComplexSelector? {
            let tokens = CSSParser.trimWhitespace(rawTokens)
            guard !tokens.isEmpty else { return nil }

            var index = 0
            guard let head = parseCompoundSelector(tokens: tokens, index: &index) else {
                return nil
            }
            var rest: [(CSSCombinator, CSSCompoundSelector)] = []
            while index < tokens.count {
                var combinator: CSSCombinator?
                var sawWhitespace = false
                while index < tokens.count, case .whitespace = tokens[index] {
                    sawWhitespace = true
                    index += 1
                }
                if index < tokens.count, case .delim(0x3E) = tokens[index] { // >
                    combinator = .child
                    index += 1
                    while index < tokens.count, case .whitespace = tokens[index] {
                        index += 1
                    }
                } else if sawWhitespace {
                    combinator = .descendant
                }

                guard let resolvedCombinator = combinator,
                      let nextCompound = parseCompoundSelector(tokens: tokens, index: &index) else {
                    return nil
                }
                rest.append((resolvedCombinator, nextCompound))
                guard rest.count < 8 else { return nil }
            }
            return CSSComplexSelector(head: head, rest: rest)
        }

        private static func parseCompoundSelector(tokens: [CSSToken], index: inout Int) -> CSSCompoundSelector? {
            var tag: String?
            var classes: [String] = []
            var ids: [String] = []
            var matchedAny = false

            if index < tokens.count, case .ident(let rawTag) = tokens[index] {
                let lowerTag = rawTag.lowercased()
                guard allowedTags.contains(lowerTag) else {
                    return nil
                }
                tag = lowerTag
                matchedAny = true
                index += 1
            }

            while index < tokens.count {
                switch tokens[index] {
                case .delim(0x2E): // '.'
                    guard index + 1 < tokens.count, case .ident(let clsRaw) = tokens[index + 1] else {
                        return nil
                    }
                    let cls = clsRaw.precomposedStringWithCanonicalMapping
                    guard EPUBAuthorStyles.isValidAuthorClassToken(cls) else {
                        return nil
                    }
                    classes.append(cls)
                    matchedAny = true
                    index += 2
                case .hash(let idRaw, let isID):
                    guard isID else { return nil }
                    let normalized = idRaw.precomposedStringWithCanonicalMapping
                    let lower = normalized.lowercased()
                    guard EPUBResourcePath.isValidFragmentID(normalized),
                          !lower.hasPrefix("yj-"),
                          !lower.hasPrefix("data-yj-") else {
                        return nil
                    }
                    ids.append(normalized)
                    matchedAny = true
                    index += 1
                case .whitespace, .delim(0x3E):
                    return matchedAny ? CSSCompoundSelector(tag: tag, classes: classes, ids: ids) : nil
                default:
                    return nil
                }
            }

            return matchedAny ? CSSCompoundSelector(tag: tag, classes: classes, ids: ids) : nil
        }
    }

    // MARK: - CSS Declarations & @font-face

    struct InlineRuleKey: Hashable {
        let isBody: Bool
        let declarations: [SanitizedDeclaration]
    }

    struct ParsedInlineRule {
        let className: String
        let isBody: Bool
        let declarations: [SanitizedDeclaration]
    }

    struct ParsedStyleRule {
        let selectors: [CSSComplexSelector]
        let declarations: [SanitizedDeclaration]
    }

    struct ParsedFontFace {
        let familyKey: String
        let sources: [(canonicalPath: String, mediaType: String)]
        let descriptors: [(String, String)]

        func render(scopedFamilyName: String) -> String {
            var parts: [String] = []
            parts.append("font-family: \"\(escapeCSSString(scopedFamilyName))\"")
            let srcItems = sources.map { source in
                let fmt = source.mediaType == "font/otf" ? "opentype" : "truetype"
                let encodedPath = EPUBAuthorStyles.rootRelativeEncodedPath(for: source.canonicalPath)
                return "url(\"\(escapeCSSString(encodedPath))\") format(\"\(fmt)\")"
            }
            parts.append("src: \(srcItems.joined(separator: ", "))")
            for (k, v) in descriptors {
                parts.append("\(k): \(v)")
            }
            return "@font-face { \(parts.joined(separator: "; ")); }"
        }
    }

    enum FontFamilyItem: Hashable {
        case generic(String)
        case custom(String)

        func render(fontFamilyMap: [String: String]) -> String? {
            switch self {
            case .generic(let keyword):
                return keyword
            case .custom(let raw):
                let lower = raw.lowercased()
                if let scoped = fontFamilyMap[lower] {
                    return "\"\(escapeCSSString(scoped))\""
                }
                if lower.hasPrefix("yjfont-") {
                    return nil
                }
                return "\"\(escapeCSSString(raw))\""
            }
        }
    }

    enum SanitizedDeclarationValue: Hashable {
        case raw(String)
        case fontFamily([FontFamilyItem])
        case fontShorthand(prefix: String, families: [FontFamilyItem])

        func render(fontFamilyMap: [String: String]) -> String {
            switch self {
            case .raw(let value):
                return value
            case .fontFamily(let items):
                let rendered = items.compactMap { $0.render(fontFamilyMap: fontFamilyMap) }
                return rendered.isEmpty ? "inherit" : rendered.joined(separator: ", ")
            case .fontShorthand(let prefix, let items):
                let rendered = items.compactMap { $0.render(fontFamilyMap: fontFamilyMap) }
                let familyString = rendered.isEmpty ? "serif" : rendered.joined(separator: ", ")
                return prefix + " " + familyString
            }
        }
    }

    struct SanitizedDeclaration: Hashable {
        let name: String
        let value: SanitizedDeclarationValue

        func render(fontFamilyMap: [String: String]) -> String {
            "\(name): \(value.render(fontFamilyMap: fontFamilyMap))"
        }
    }

    private final class SanitizationContext {
        unowned let collector: ChapterCollector
        let cssSourcePath: String

        init(collector: ChapterCollector, cssSourcePath: String) {
            self.collector = collector
            self.cssSourcePath = cssSourcePath
        }

        var manifestByPath: [String: String] { collector.manifestByPath }
        var destination: URL { collector.destination }
        var cache: ValidationCache? { collector.cache }

        func validateCharsetRule(prelude: [CSSToken], block: [CSSToken]?) throws {
            guard block == nil else {
                throw EPUBError.unsupportedContent
            }
            let trimmed = CSSParser.trimWhitespace(prelude)
            guard trimmed.count == 1, case .string(let encoding) = trimmed[0] else {
                throw EPUBError.unsupportedContent
            }
            let lower = encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard lower == "utf-8" || lower == "utf8" || lower == "us-ascii" || lower == "ascii" else {
                throw EPUBError.unsupportedContent
            }
        }

        func auditDeclarations(_ declarations: [CSSDeclaration]) throws {
            for decl in declarations {
                let lowerName = decl.name.lowercased()
                if lowerName == "behavior" || lowerName == "-moz-binding" {
                    throw EPUBError.unsupportedContent
                }
                try auditRawTokens(decl.valueTokens)
            }
        }

        func auditRawTokens(_ tokens: [CSSToken]) throws {
            var index = 0
            while index < tokens.count {
                switch tokens[index] {
                case .badString, .badUrl:
                    throw EPUBError.unsupportedContent
                case .atKeyword(let kw):
                    if kw.lowercased() == "import" {
                        throw EPUBError.unsupportedContent
                    }
                    index += 1
                case .url(let rawURL):
                    _ = try auditNonFontURL(rawURL)
                    index += 1
                case .function(let fn):
                    let lowerFn = fn.lowercased()
                    if lowerFn == "expression" {
                        throw EPUBError.unsupportedContent
                    }
                    if lowerFn == "url" {
                        let (rawURL, nextIndex) = try extractFunctionURL(tokens: tokens, startAtFunctionIndex: index)
                        _ = try auditNonFontURL(rawURL)
                        index = nextIndex
                        continue
                    }
                    index += 1
                case .ident(let ident):
                    let lower = ident.lowercased()
                    if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") {
                        throw EPUBError.unsupportedContent
                    }
                    if lower == "behavior" || lower == "-moz-binding" {
                        var peek = index + 1
                        while peek < tokens.count, case .whitespace = tokens[peek] {
                            peek += 1
                        }
                        if peek < tokens.count, case .colon = tokens[peek] {
                            throw EPUBError.unsupportedContent
                        }
                    }
                    index += 1
                case .string(let str):
                    if hasActiveOrExternalPrefix(str) {
                        throw EPUBError.unsupportedContent
                    }
                    index += 1
                default:
                    index += 1
                }
            }
        }

        private func extractFunctionURL(tokens: [CSSToken], startAtFunctionIndex index: Int) throws -> (String, Int) {
            var cursor = index + 1
            while cursor < tokens.count, case .whitespace = tokens[cursor] {
                cursor += 1
            }
            guard cursor < tokens.count, case .string(let rawURL) = tokens[cursor] else {
                throw EPUBError.unsupportedContent
            }
            cursor += 1
            while cursor < tokens.count, case .whitespace = tokens[cursor] {
                cursor += 1
            }
            guard cursor < tokens.count, case .rparen = tokens[cursor] else {
                throw EPUBError.unsupportedContent
            }
            return (rawURL, cursor + 1)
        }

        private func hasActiveOrExternalPrefix(_ raw: String) -> Bool {
            let stripped = String(raw.unicodeScalars.filter { scalar in
                !scalar.properties.isWhitespace && scalar.value >= 0x20 && scalar.value != 0x7F
            }).lowercased()
            if stripped.hasPrefix("javascript:") ||
                stripped.hasPrefix("vbscript:") ||
                stripped.hasPrefix("data:") ||
                stripped.hasPrefix("http:") ||
                stripped.hasPrefix("https:") ||
                stripped.hasPrefix("file:") ||
                stripped.hasPrefix("blob:") ||
                stripped.hasPrefix("ftp:") ||
                stripped.hasPrefix("mailto:") ||
                stripped.hasPrefix("tel:") ||
                stripped.hasPrefix("yjepub:") ||
                stripped.hasPrefix("//") {
                return true
            }
            return false
        }

        @discardableResult
        private func auditNonFontURL(_ rawURL: String) throws -> String {
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw EPUBError.unsupportedContent
            }
            guard !hasActiveOrExternalPrefix(trimmed) else {
                throw EPUBError.unsupportedContent
            }
            let resolved = try EPUBResourcePath.resolve(trimmed, relativeTo: cssSourcePath)
            guard resolved.fragment == nil,
                  let mediaType = manifestByPath[resolved.path] else {
                throw EPUBError.invalidPackage
            }
            let lowerType = mediaType.lowercased()
            if lowerType.contains("javascript") || lowerType.contains("html") || lowerType.contains("svg") {
                throw EPUBError.unsupportedContent
            }
            return resolved.path
        }

        func parseFontFace(blockTokens: [CSSToken]) throws -> ParsedFontFace {
            let declarations = try CSSParser.parseDeclarationList(blockTokens)
            guard !declarations.isEmpty else {
                throw EPUBError.unsupportedContent
            }
            try auditDeclarations(declarations.filter { $0.name.lowercased() != "src" })

            var familyName: String?
            var srcTokens: [CSSToken]?
            var descriptors: [(String, String)] = []

            for decl in declarations {
                let lowerName = decl.name.lowercased()
                switch lowerName {
                case "font-family":
                    guard let parsed = parseSingleFontFamilyName(decl.valueTokens) else {
                        throw EPUBError.unsupportedContent
                    }
                    familyName = parsed
                case "src":
                    srcTokens = decl.valueTokens
                case "font-style":
                    if let v = parseFontStyle(decl.valueTokens) {
                        descriptors.append(("font-style", v))
                    }
                case "font-weight":
                    if let v = parseFontFaceWeight(decl.valueTokens) {
                        descriptors.append(("font-weight", v))
                    }
                case "font-stretch":
                    if let v = parseFontStretch(decl.valueTokens) {
                        descriptors.append(("font-stretch", v))
                    }
                case "font-display":
                    if let v = parseFontDisplay(decl.valueTokens) {
                        descriptors.append(("font-display", v))
                    }
                default:
                    break
                }
            }
            guard let resolvedFamily = familyName,
                  !resolvedFamily.isEmpty,
                  !resolvedFamily.lowercased().hasPrefix("yjfont-"),
                  let rawSrc = srcTokens,
                  !rawSrc.isEmpty else {
                throw EPUBError.unsupportedContent
            }
            let sources = try parseAndValidateFontFaceSrc(rawSrc)
            guard !sources.isEmpty else {
                throw EPUBError.unsupportedContent
            }

            return ParsedFontFace(
                familyKey: resolvedFamily.lowercased(),
                sources: sources,
                descriptors: descriptors
            )
        }

        private func parseSingleFontFamilyName(_ tokens: [CSSToken]) -> String? {
            let trimmed = CSSParser.trimWhitespace(tokens)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.count == 1, case .string(let s) = trimmed[0] {
                let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 256, !hasActiveOrExternalPrefix(clean) else { return nil }
                return clean
            }
            var parts: [String] = []
            for token in trimmed {
                switch token {
                case .ident(let word):
                    parts.append(word)
                case .whitespace:
                    continue
                default:
                    return nil
                }
            }
            let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, joined.count <= 256 else { return nil }
            return joined
        }

        private func parseAndValidateFontFaceSrc(_ tokens: [CSSToken]) throws -> [(canonicalPath: String, mediaType: String)] {
            var groups: [[CSSToken]] = []
            var current: [CSSToken] = []
            var depth = 0
            for token in tokens {
                switch token {
                case .lparen, .lbracket, .lbrace, .function:
                    depth += 1
                    current.append(token)
                case .rparen, .rbracket, .rbrace:
                    depth = max(0, depth - 1)
                    current.append(token)
                case .comma where depth == 0:
                    groups.append(current)
                    current = []
                default:
                    current.append(token)
                }
            }
            groups.append(current)
            guard groups.count <= 16 else {
                throw EPUBError.limitExceeded
            }

            var validSources: [(canonicalPath: String, mediaType: String)] = []
            for group in groups {
                let item = CSSParser.trimWhitespace(group)
                guard !item.isEmpty else {
                    throw EPUBError.unsupportedContent
                }
                var cursor = 0
                switch item[0] {
                case .function(let fn) where fn.lowercased() == "local":
                    // local(...) alone is unsupported; ignore only if balanced and valid local name.
                    var inner = cursor + 1
                    while inner < item.count {
                        if case .badString = item[inner] { throw EPUBError.unsupportedContent }
                        if case .badUrl = item[inner] { throw EPUBError.unsupportedContent }
                        if case .rparen = item[inner] {
                            inner += 1
                            break
                        }
                        inner += 1
                    }
                    while inner < item.count, case .whitespace = item[inner] { inner += 1 }
                    guard inner == item.count else {
                        throw EPUBError.unsupportedContent
                    }
                    continue
                case .url(let rawURL):
                    cursor = 1
                    if let verified = try validateFontSourceItem(rawURL: rawURL, trailingTokens: Array(item[cursor...])) {
                        validSources.append(verified)
                    }
                case .function(let fn) where fn.lowercased() == "url":
                    let (rawURL, nextIndex) = try extractFunctionURL(tokens: item, startAtFunctionIndex: 0)
                    if let verified = try validateFontSourceItem(rawURL: rawURL, trailingTokens: Array(item[nextIndex...])) {
                        validSources.append(verified)
                    }
                default:
                    throw EPUBError.unsupportedContent
                }
            }

            return validSources
        }

        private func validateFontSourceItem(rawURL: String, trailingTokens: [CSSToken]) throws -> (canonicalPath: String, mediaType: String)? {
            let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else {
                throw EPUBError.unsupportedContent
            }
            guard !hasActiveOrExternalPrefix(trimmedURL) else {
                throw EPUBError.unsupportedContent
            }

            // Parse optional format("...") or tech(...)
            var declaredFormat: String?
            let trailing = CSSParser.trimWhitespace(trailingTokens)
            var tIndex = 0
            while tIndex < trailing.count {
                switch trailing[tIndex] {
                case .whitespace:
                    tIndex += 1
                case .function(let fn) where fn.lowercased() == "format":
                    var inner = tIndex + 1
                    while inner < trailing.count, case .whitespace = trailing[inner] { inner += 1 }
                    guard inner < trailing.count else { throw EPUBError.unsupportedContent }
                    let fmt: String
                    switch trailing[inner] {
                    case .string(let s): fmt = s.lowercased()
                    case .ident(let id): fmt = id.lowercased()
                    default: throw EPUBError.unsupportedContent
                    }
                    inner += 1
                    while inner < trailing.count, case .whitespace = trailing[inner] { inner += 1 }
                    guard inner < trailing.count, case .rparen = trailing[inner] else {
                        throw EPUBError.unsupportedContent
                    }
                    declaredFormat = fmt
                    tIndex = inner + 1
                default:
                    throw EPUBError.unsupportedContent
                }
            }

            let resolved = try EPUBResourcePath.resolve(trimmedURL, relativeTo: cssSourcePath)
            guard resolved.fragment == nil else {
                throw EPUBError.invalidPackage
            }

            let lowerPath = resolved.path.lowercased()
            if lowerPath.hasSuffix(".woff") || lowerPath.hasSuffix(".woff2") ||
                lowerPath.hasSuffix(".eot") || lowerPath.hasSuffix(".svg") ||
                lowerPath.hasSuffix(".ttc") || lowerPath.hasSuffix(".dfont") {
                return nil
            }
            if let fmt = declaredFormat {
                if fmt == "woff" || fmt == "woff2" || fmt == "embedded-opentype" || fmt == "svg" {
                    return nil
                }
                guard fmt == "truetype" || fmt == "opentype" || fmt == "truetype-aat" else {
                    return nil
                }
            }

            guard let manifestType = manifestByPath[resolved.path] else {
                throw EPUBError.invalidPackage
            }
            guard EPUBAuthorStyles.isSupportedFontManifestMediaType(manifestType) else {
                throw EPUBError.unsupportedContent
            }

            let canonicalMediaType: String
            if let cached = cache?.verifiedFonts[resolved.path] {
                canonicalMediaType = cached
            } else {
                let verified = try EPUBAuthorStyles.verifyExtractedFont(
                    at: resolved.path,
                    under: destination,
                    declaredMediaType: manifestType
                )
                canonicalMediaType = verified.mediaType
                cache?.verifiedFonts[resolved.path] = canonicalMediaType
            }

            try collector.recordReferencedFont(path: resolved.path, mediaType: canonicalMediaType)
            return (canonicalPath: resolved.path, mediaType: canonicalMediaType)
        }

        // MARK: - Declaration Whitelist

        func sanitizeDeclarations(_ declarations: [CSSDeclaration], isRootScope: Bool) throws -> [SanitizedDeclaration] {
            try auditDeclarations(declarations)
            var sanitized: [SanitizedDeclaration] = []
            for decl in declarations {
                let prop = decl.name.lowercased()
                guard !prop.isEmpty, !prop.hasPrefix("--") else {
                    continue
                }
                if let result = sanitizeSingleDeclaration(prop: prop, tokens: decl.valueTokens, isRootScope: isRootScope) {
                    sanitized.append(result)
                }
            }
            return sanitized
        }

        private func sanitizeSingleDeclaration(prop: String, tokens: [CSSToken], isRootScope: Bool) -> SanitizedDeclaration? {
            let clean = CSSParser.trimWhitespace(tokens)
            guard !clean.isEmpty else { return nil }

            // Check for global keywords inherit/initial/unset? Allow "inherit" on most safe props, drop otherwise.
            if clean.count == 1, case .ident(let kw) = clean[0], kw.lowercased() == "inherit" {
                if Self.allowedSimpleProperties.contains(prop) {
                    return SanitizedDeclaration(name: prop, value: .raw("inherit"))
                }
            }

            switch prop {
            case "font-family":
                guard let families = parseFontFamilyList(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .fontFamily(families))
            case "font":
                return parseFontShorthand(clean)
            case "font-size":
                guard let v = parseFontSize(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "font-weight":
                guard let v = parseFontWeight(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "font-style":
                guard let v = parseFontStyle(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "font-variant":
                guard let v = parseKeyword(clean, allowed: ["normal", "small-caps"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "font-variant-caps":
                guard let v = parseKeyword(clean, allowed: ["normal", "small-caps", "all-small-caps", "petite-caps", "all-petite-caps", "unicase", "titling-caps"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "line-height":
                guard let v = parseLineHeight(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "letter-spacing", "word-spacing":
                if let v = parseKeyword(clean, allowed: ["normal"]) {
                    return SanitizedDeclaration(name: prop, value: .raw(v))
                }
                guard let v = parseLength(clean, allowNegative: true) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-indent":
                guard let v = parseLengthOrPercentage(clean, allowNegative: true) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-align":
                guard let v = parseKeyword(clean, allowed: ["left", "right", "center", "justify", "start", "end", "match-parent"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-align-last":
                guard let v = parseKeyword(clean, allowed: ["auto", "start", "end", "left", "right", "center", "justify"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-decoration":
                guard let v = parseTextDecoration(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-decoration-line":
                guard let v = parseTextDecorationLine(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-decoration-style":
                guard let v = parseKeyword(clean, allowed: ["solid", "double", "dotted", "dashed", "wavy"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "text-decoration-color", "color", "background-color":
                guard let v = parseColor(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "background":
                if let kw = parseKeyword(clean, allowed: ["none", "transparent"]) {
                    return SanitizedDeclaration(name: "background-color", value: .raw(kw == "none" ? "transparent" : kw))
                }
                guard let v = parseColor(clean) else { return nil }
                return SanitizedDeclaration(name: "background-color", value: .raw(v))
            case "text-transform":
                guard let v = parseKeyword(clean, allowed: ["none", "capitalize", "uppercase", "lowercase", "full-width"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "vertical-align":
                if let v = parseKeyword(clean, allowed: ["baseline", "sub", "super", "top", "text-top", "middle", "bottom", "text-bottom"]) {
                    return SanitizedDeclaration(name: prop, value: .raw(v))
                }
                guard let v = parseLengthOrPercentage(clean, allowNegative: true) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "white-space":
                guard let v = parseKeyword(clean, allowed: ["normal", "nowrap", "pre", "pre-wrap", "pre-line", "break-spaces"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "word-break":
                guard let v = parseKeyword(clean, allowed: ["normal", "break-all", "keep-all", "break-word"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "overflow-wrap", "word-wrap":
                guard let v = parseKeyword(clean, allowed: ["normal", "break-word", "anywhere"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "hyphens":
                guard let v = parseKeyword(clean, allowed: ["none", "manual", "auto"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "direction":
                guard let v = parseKeyword(clean, allowed: ["ltr", "rtl"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "margin":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 4, allowAuto: true, allowNegative: true) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "margin-block", "margin-inline":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 2, allowAuto: true, allowNegative: true) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "margin-top", "margin-right", "margin-bottom", "margin-left",
                 "margin-block-start", "margin-block-end", "margin-inline-start", "margin-inline-end":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 1, allowAuto: true, allowNegative: true) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "padding":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 4, allowAuto: false, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "padding-block", "padding-inline":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 2, allowAuto: false, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "padding-top", "padding-right", "padding-bottom", "padding-left",
                 "padding-block-start", "padding-block-end", "padding-inline-start", "padding-inline-end":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 1, allowAuto: false, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border", "border-top", "border-right", "border-bottom", "border-left":
                guard let v = parseBorderShorthand(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-width":
                guard let v = parseMultiLineWidth(clean, minCount: 1, maxCount: 4) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-top-width", "border-right-width", "border-bottom-width", "border-left-width":
                guard let v = parseMultiLineWidth(clean, minCount: 1, maxCount: 1) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-style":
                guard let v = parseMultiLineStyle(clean, minCount: 1, maxCount: 4) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-top-style", "border-right-style", "border-bottom-style", "border-left-style":
                guard let v = parseMultiLineStyle(clean, minCount: 1, maxCount: 1) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-color":
                guard let v = parseMultiColor(clean, minCount: 1, maxCount: 4) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-top-color", "border-right-color", "border-bottom-color", "border-left-color":
                guard let v = parseColor(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-radius":
                guard let v = parseBorderRadius(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius":
                guard let v = parseBoxLengths(clean, minCount: 1, maxCount: 2, allowAuto: false, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-collapse":
                guard let v = parseKeyword(clean, allowed: ["collapse", "separate"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "border-spacing":
                guard let v = parseLengthsOnly(clean, minCount: 1, maxCount: 2, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "box-sizing":
                guard let v = parseKeyword(clean, allowed: ["content-box", "border-box"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "float":
                guard !isRootScope,
                      let v = parseKeyword(clean, allowed: ["left", "right", "none", "inline-start", "inline-end"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "clear":
                guard let v = parseKeyword(clean, allowed: ["left", "right", "both", "none", "inline-start", "inline-end"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "width", "height", "min-width", "min-height":
                if let v = parseKeyword(clean, allowed: ["auto"]) {
                    return SanitizedDeclaration(name: prop, value: .raw(v))
                }
                guard let v = parseLengthOrPercentage(clean, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "max-width", "max-height":
                if let v = parseKeyword(clean, allowed: ["none"]) {
                    return SanitizedDeclaration(name: prop, value: .raw(v))
                }
                guard let v = parseLengthOrPercentage(clean, allowNegative: false) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "object-fit":
                guard let v = parseKeyword(clean, allowed: ["contain", "cover", "fill", "scale-down", "none"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "display":
                var allowed: Set<String> = [
                    "block", "inline", "inline-block", "list-item",
                    "table", "table-row", "table-cell", "table-caption",
                    "table-header-group", "table-footer-group", "table-row-group",
                    "table-column", "table-column-group"
                ]
                if !isRootScope {
                    allowed.insert("none")
                }
                guard let v = parseKeyword(clean, allowed: allowed) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "list-style-type":
                guard let v = parseKeyword(clean, allowed: Self.allowedListStyleTypes) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "list-style-position":
                guard let v = parseKeyword(clean, allowed: ["inside", "outside"]) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            case "list-style":
                guard let v = parseListStyleShorthand(clean) else { return nil }
                return SanitizedDeclaration(name: prop, value: .raw(v))
            default:
                return nil
            }
        }

        private static let allowedSimpleProperties: Set<String> = [
            "font-family", "font-size", "font-weight", "font-style", "font-variant", "font-variant-caps",
            "line-height", "letter-spacing", "word-spacing", "text-indent", "text-align", "text-align-last",
            "text-decoration", "text-decoration-line", "text-decoration-style", "text-decoration-color",
            "text-transform", "vertical-align", "white-space", "word-break", "overflow-wrap", "word-wrap",
            "hyphens", "direction", "color", "background-color",
            "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
            "margin-block", "margin-block-start", "margin-block-end", "margin-inline", "margin-inline-start", "margin-inline-end",
            "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
            "padding-block", "padding-block-start", "padding-block-end", "padding-inline", "padding-inline-start", "padding-inline-end",
            "border", "border-top", "border-right", "border-bottom", "border-left",
            "border-width", "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
            "border-style", "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
            "border-color", "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
            "border-radius", "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius",
            "border-collapse", "border-spacing", "box-sizing", "float", "clear",
            "width", "height", "min-width", "max-width", "min-height", "max-height",
            "object-fit", "list-style", "list-style-type", "list-style-position"
        ]

        private static let allowedLengthUnits: Set<String> = [
            "px", "em", "rem", "pt", "pc", "ex", "ch", "cm", "mm", "in", "q"
        ]

        private static let allowedGenericFontFamilies: Set<String> = [
            "serif", "sans-serif", "monospace", "cursive", "fantasy",
            "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace"
        ]

        private static let allowedLineStyles: Set<String> = [
            "none", "hidden", "dotted", "dashed", "solid", "double", "groove", "ridge", "inset", "outset"
        ]

        private static let allowedListStyleTypes: Set<String> = [
            "none", "disc", "circle", "square", "decimal", "decimal-leading-zero",
            "lower-roman", "upper-roman", "lower-greek", "lower-latin", "upper-latin",
            "lower-alpha", "upper-alpha", "cjk-ideographic", "hiragana", "katakana",
            "simp-chinese-formal", "simp-chinese-informal",
            "trad-chinese-formal", "trad-chinese-informal"
        ]

        private static let allowedNamedColors: Set<String> = [
            "transparent", "currentcolor",
            "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black",
            "blanchedalmond", "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse",
            "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue",
            "darkcyan", "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki", "darkmagenta",
            "darkolivegreen", "darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen",
            "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise", "darkviolet",
            "deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick", "floralwhite",
            "forestgreen", "fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod", "gray",
            "green", "greenyellow", "grey", "honeydew", "hotpink", "indianred", "indigo", "ivory",
            "khaki", "lavender", "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral",
            "lightcyan", "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink",
            "lightsalmon", "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey",
            "lightsteelblue", "lightyellow", "lime", "limegreen", "linen", "magenta", "maroon",
            "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple", "mediumseagreen",
            "mediumslateblue", "mediumspringgreen", "mediumturquoise", "mediumvioletred", "midnightblue",
            "mintcream", "mistyrose", "moccasin", "navajowhite", "navy", "oldlace", "olive",
            "olivedrab", "orange", "orangered", "orchid", "palegoldenrod", "palegreen", "paleturquoise",
            "palevioletred", "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple",
            "rebeccapurple", "red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown",
            "seagreen", "seashell", "sienna", "silver", "skyblue", "slateblue", "slategray", "slategrey",
            "snow", "springgreen", "steelblue", "tan", "teal", "thistle", "tomato", "turquoise",
            "violet", "wheat", "white", "whitesmoke", "yellow", "yellowgreen"
        ]

        // MARK: - Primitive Value Parsers

        private func parseKeyword(_ tokens: [CSSToken], allowed: Set<String>) -> String? {
            guard tokens.count == 1, case .ident(let word) = tokens[0] else { return nil }
            let lower = word.lowercased()
            return allowed.contains(lower) ? lower : nil
        }

        private func parseLength(_ tokens: [CSSToken], allowNegative: Bool) -> String? {
            guard tokens.count == 1 else { return nil }
            return parseSingleLengthToken(tokens[0], allowNegative: allowNegative)
        }

        private func parseSingleLengthToken(_ token: CSSToken, allowNegative: Bool) -> String? {
            switch token {
            case .number(let val, _, _):
                guard val == 0 else { return nil }
                return "0"
            case .dimension(let val, let raw, let unit):
                let lowerUnit = unit.lowercased()
                guard val.isFinite,
                      abs(val) <= 10_000,
                      allowNegative || val >= 0,
                      Self.allowedLengthUnits.contains(lowerUnit) else {
                    return nil
                }
                return raw + lowerUnit
            default:
                return nil
            }
        }

        private func parseSingleLengthOrPercentageToken(_ token: CSSToken, allowNegative: Bool) -> String? {
            if let len = parseSingleLengthToken(token, allowNegative: allowNegative) {
                return len
            }
            if case .percentage(let val, let raw) = token,
               val.isFinite,
               abs(val) <= 10_000,
               allowNegative || val >= 0 {
                return raw + "%"
            }
            return nil
        }

        private func parseLengthOrPercentage(_ tokens: [CSSToken], allowNegative: Bool) -> String? {
            guard tokens.count == 1 else { return nil }
            return parseSingleLengthOrPercentageToken(tokens[0], allowNegative: allowNegative)
        }

        private func parseLengthsOnly(_ tokens: [CSSToken], minCount: Int, maxCount: Int, allowNegative: Bool) -> String? {
            var values: [String] = []
            for token in tokens {
                if case .whitespace = token { continue }
                guard let len = parseSingleLengthToken(token, allowNegative: allowNegative) else { return nil }
                values.append(len)
            }
            guard values.count >= minCount, values.count <= maxCount else { return nil }
            return values.joined(separator: " ")
        }

        private func parseBoxLengths(_ tokens: [CSSToken], minCount: Int, maxCount: Int, allowAuto: Bool, allowNegative: Bool) -> String? {
            var values: [String] = []
            for token in tokens {
                if case .whitespace = token { continue }
                if allowAuto, case .ident(let word) = token, word.lowercased() == "auto" {
                    values.append("auto")
                    continue
                }
                guard let parsed = parseSingleLengthOrPercentageToken(token, allowNegative: allowNegative) else {
                    return nil
                }
                values.append(parsed)
            }
            guard values.count >= minCount, values.count <= maxCount else { return nil }
            return values.joined(separator: " ")
        }

        private func parseFontSize(_ tokens: [CSSToken]) -> String? {
            let keywords: Set<String> = [
                "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large", "smaller", "larger"
            ]
            if let kw = parseKeyword(tokens, allowed: keywords) {
                return kw
            }
            return parseLengthOrPercentage(tokens, allowNegative: false)
        }

        private func parseFontWeight(_ tokens: [CSSToken]) -> String? {
            if let kw = parseKeyword(tokens, allowed: ["normal", "bold", "bolder", "lighter"]) {
                return kw
            }
            guard tokens.count == 1, case .number(let val, let raw, _) = tokens[0],
                  val.isFinite, val >= 1, val <= 1000 else {
                return nil
            }
            return raw
        }

        private func parseFontFaceWeight(_ tokens: [CSSToken]) -> String? {
            var parts: [String] = []
            for token in tokens {
                switch token {
                case .whitespace: continue
                case .ident(let word) where word.lowercased() == "normal" || word.lowercased() == "bold":
                    parts.append(word.lowercased())
                case .number(let val, let raw, _) where val.isFinite && val >= 1 && val <= 1000:
                    parts.append(raw)
                default:
                    return nil
                }
            }
            guard parts.count == 1 || parts.count == 2 else { return nil }
            return parts.joined(separator: " ")
        }

        private func parseFontStyle(_ tokens: [CSSToken]) -> String? {
            parseKeyword(tokens, allowed: ["normal", "italic", "oblique"])
        }

        private func parseFontStretch(_ tokens: [CSSToken]) -> String? {
            let keywords: Set<String> = [
                "normal", "ultra-condensed", "extra-condensed", "condensed", "semi-condensed",
                "semi-expanded", "expanded", "extra-expanded", "ultra-expanded"
            ]
            if let kw = parseKeyword(tokens, allowed: keywords) {
                return kw
            }
            if tokens.count == 1, case .percentage(let val, let raw) = tokens[0],
               val.isFinite, val >= 50, val <= 200 {
                return raw + "%"
            }
            return nil
        }

        private func parseFontDisplay(_ tokens: [CSSToken]) -> String? {
            parseKeyword(tokens, allowed: ["auto", "block", "swap", "fallback", "optional"])
        }

        private func parseLineHeight(_ tokens: [CSSToken]) -> String? {
            if let kw = parseKeyword(tokens, allowed: ["normal"]) {
                return kw
            }
            guard tokens.count == 1 else { return nil }
            if case .number(let val, let raw, _) = tokens[0] {
                guard val.isFinite, val >= 0, val <= 20 else { return nil }
                return raw
            }
            return parseSingleLengthOrPercentageToken(tokens[0], allowNegative: false)
        }

        private func parseFontFamilyList(_ tokens: [CSSToken]) -> [FontFamilyItem]? {
            var groups: [[CSSToken]] = []
            var current: [CSSToken] = []
            for token in tokens {
                if case .comma = token {
                    groups.append(current)
                    current = []
                } else {
                    current.append(token)
                }
            }
            groups.append(current)
            guard !groups.isEmpty, groups.count <= 16 else { return nil }

            var items: [FontFamilyItem] = []
            for group in groups {
                let trimmed = CSSParser.trimWhitespace(group)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.count == 1, case .string(let s) = trimmed[0] {
                    let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty, clean.count <= 256, !hasActiveOrExternalPrefix(clean) else { return nil }
                    items.append(.custom(clean))
                    continue
                }
                var words: [String] = []
                for tok in trimmed {
                    switch tok {
                    case .ident(let word): words.append(word)
                    case .whitespace: continue
                    default: return nil
                    }
                }
                guard !words.isEmpty else { return nil }
                let joined = words.joined(separator: " ")
                if words.count == 1, Self.allowedGenericFontFamilies.contains(joined.lowercased()) {
                    items.append(.generic(joined.lowercased()))
                } else {
                    items.append(.custom(joined))
                }
            }
            return items
        }

        private func parseFontShorthand(_ tokens: [CSSToken]) -> SanitizedDeclaration? {
            let nonSpace = tokens.filter {
                if case .whitespace = $0 { return false }
                return true
            }
            guard nonSpace.count >= 2 else { return nil }

            var index = 0
            var styleVal: String?
            var variantVal: String?
            var weightVal: String?

            // Parse optional style / variant / weight before font-size.
            while index < nonSpace.count {
                switch nonSpace[index] {
                case .ident(let word):
                    let lower = word.lowercased()
                    if ["italic", "oblique"].contains(lower), styleVal == nil {
                        styleVal = lower
                        index += 1
                    } else if lower == "small-caps", variantVal == nil {
                        variantVal = lower
                        index += 1
                    } else if ["bold", "bolder", "lighter"].contains(lower), weightVal == nil {
                        weightVal = lower
                        index += 1
                    } else if lower == "normal" {
                        index += 1
                    } else {
                        break
                    }
                    continue
                case .number(let val, let raw, _) where val.isFinite && val >= 1 && val <= 1000 && weightVal == nil:
                    weightVal = raw
                    index += 1
                    continue
                default:
                    break
                }
                break
            }

            guard index < nonSpace.count, let sizeStr = parseFontSize([nonSpace[index]]) else {
                return nil
            }
            index += 1

            var lineHeightStr: String?
            if index < nonSpace.count, case .delim(0x2F) = nonSpace[index] { // '/'
                index += 1
                guard index < nonSpace.count, let lh = parseLineHeight([nonSpace[index]]) else {
                    return nil
                }
                lineHeightStr = lh
                index += 1
            }

            // Remaining tokens from original `tokens` correspond to font-family.
            // Rebuild remaining tokens using original stream after matching nonSpace count.
            var remainingNonSpaceSeen = 0
            var splitRawIndex = 0
            while splitRawIndex < tokens.count && remainingNonSpaceSeen < index {
                if case .whitespace = tokens[splitRawIndex] {
                    splitRawIndex += 1
                    continue
                }
                remainingNonSpaceSeen += 1
                splitRawIndex += 1
            }
            let familyTokens = CSSParser.trimWhitespace(Array(tokens[splitRawIndex...]))
            guard let families = parseFontFamilyList(familyTokens) else {
                return nil
            }

            var prefixParts: [String] = []
            if let styleVal { prefixParts.append(styleVal) }
            if let variantVal { prefixParts.append(variantVal) }
            if let weightVal { prefixParts.append(weightVal) }
            if let lineHeightStr {
                prefixParts.append("\(sizeStr)/\(lineHeightStr)")
            } else {
                prefixParts.append(sizeStr)
            }

            return SanitizedDeclaration(
                name: "font",
                value: .fontShorthand(prefix: prefixParts.joined(separator: " "), families: families)
            )
        }

        private func parseColor(_ tokens: [CSSToken]) -> String? {
            guard tokens.count >= 1 else { return nil }
            if tokens.count == 1 {
                return parseSingleColorToken(tokens[0])
            }
            // Function color: rgb(...), rgba(...), hsl(...), hsla(...)
            guard case .function(let fn) = tokens[0],
                  case .rparen = tokens[tokens.count - 1] else {
                return nil
            }
            let lowerFn = fn.lowercased()
            guard lowerFn == "rgb" || lowerFn == "rgba" || lowerFn == "hsl" || lowerFn == "hsla" else {
                return nil
            }
            let inner = Array(tokens[1..<(tokens.count - 1)])
            return parseColorFunction(name: lowerFn, innerTokens: inner)
        }

        private func parseSingleColorToken(_ token: CSSToken) -> String? {
            switch token {
            case .hash(let hex, _):
                let count = hex.count
                guard (count == 3 || count == 4 || count == 6 || count == 8),
                      hex.unicodeScalars.allSatisfy({
                          let v = $0.value
                          return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x46) || (v >= 0x61 && v <= 0x66)
                      }) else {
                    return nil
                }
                return "#" + hex.lowercased()
            case .ident(let name):
                let lower = name.lowercased()
                return Self.allowedNamedColors.contains(lower) ? lower : nil
            default:
                return nil
            }
        }

        private func parseColorFunction(name: String, innerTokens: [CSSToken]) -> String? {
            let trimmed = CSSParser.trimWhitespace(innerTokens)
            guard !trimmed.isEmpty else { return nil }
            var args: [String] = []
            var sawComma = false
            var sawSlash = false
            var expectArg = true
            for token in trimmed {
                switch token {
                case .whitespace:
                    continue
                case .comma:
                    guard !expectArg, !sawSlash else { return nil }
                    sawComma = true
                    expectArg = true
                case .delim(0x2F): // '/'
                    guard !expectArg, !sawComma, !sawSlash, args.count == 3 else { return nil }
                    sawSlash = true
                    expectArg = true
                case .number(let val, let raw, _) where val.isFinite && abs(val) <= 1000:
                    guard expectArg || (!sawComma && !sawSlash) else { return nil }
                    args.append(raw)
                    expectArg = false
                case .percentage(let val, let raw) where val.isFinite && val >= 0 && val <= 100:
                    guard expectArg || (!sawComma && !sawSlash) else { return nil }
                    args.append(raw + "%")
                    expectArg = false
                case .dimension(let val, let raw, let unit) where (name == "hsl" || name == "hsla") && val.isFinite && abs(val) <= 3600:
                    guard expectArg || (!sawComma && !sawSlash) else { return nil }
                    let u = unit.lowercased()
                    guard u == "deg" || u == "rad" || u == "grad" || u == "turn" else { return nil }
                    args.append(raw + u)
                    expectArg = false
                default:
                    return nil
                }
            }
            guard !expectArg, args.count == 3 || args.count == 4 else { return nil }
            if args.count == 3 {
                return "\(name)(\(args.joined(separator: ", ")))"
            }
            if sawComma || !sawSlash {
                return "\(name)(\(args.joined(separator: ", ")))"
            }
            return "\(name)(\(args[0]) \(args[1]) \(args[2]) / \(args[3]))"
        }

        private func splitColorComponentGroups(_ tokens: [CSSToken]) -> [[CSSToken]]? {
            var groups: [[CSSToken]] = []
            var index = 0
            while index < tokens.count {
                if case .whitespace = tokens[index] {
                    index += 1
                    continue
                }
                if case .function = tokens[index] {
                    let start = index
                    index += 1
                    var depth = 1
                    while index < tokens.count && depth > 0 {
                        if case .function = tokens[index] { depth += 1 }
                        else if case .lparen = tokens[index] { depth += 1 }
                        else if case .rparen = tokens[index] { depth -= 1 }
                        index += 1
                    }
                    guard depth == 0 else { return nil }
                    groups.append(Array(tokens[start..<index]))
                } else {
                    groups.append([tokens[index]])
                    index += 1
                }
            }
            return groups
        }

        private func parseMultiColor(_ tokens: [CSSToken], minCount: Int, maxCount: Int) -> String? {
            guard let groups = splitColorComponentGroups(tokens),
                  groups.count >= minCount, groups.count <= maxCount else { return nil }
            var rendered: [String] = []
            for group in groups {
                guard let color = parseColor(group) else { return nil }
                rendered.append(color)
            }
            return rendered.joined(separator: " ")
        }

        private func parseLineWidthToken(_ token: CSSToken) -> String? {
            if case .ident(let word) = token {
                let lower = word.lowercased()
                if ["thin", "medium", "thick"].contains(lower) { return lower }
                return nil
            }
            return parseSingleLengthToken(token, allowNegative: false)
        }

        private func parseMultiLineWidth(_ tokens: [CSSToken], minCount: Int, maxCount: Int) -> String? {
            var values: [String] = []
            for token in tokens {
                if case .whitespace = token { continue }
                guard let v = parseLineWidthToken(token) else { return nil }
                values.append(v)
            }
            guard values.count >= minCount, values.count <= maxCount else { return nil }
            return values.joined(separator: " ")
        }

        private func parseMultiLineStyle(_ tokens: [CSSToken], minCount: Int, maxCount: Int) -> String? {
            var values: [String] = []
            for token in tokens {
                if case .whitespace = token { continue }
                guard case .ident(let word) = token, Self.allowedLineStyles.contains(word.lowercased()) else {
                    return nil
                }
                values.append(word.lowercased())
            }
            guard values.count >= minCount, values.count <= maxCount else { return nil }
            return values.joined(separator: " ")
        }

        private func parseBorderShorthand(_ tokens: [CSSToken]) -> String? {
            if let kw = parseKeyword(tokens, allowed: ["none", "hidden"]) {
                return kw
            }
            if tokens.count == 1, case .number(0, _, _) = tokens[0] {
                return "0"
            }
            guard let groups = splitColorComponentGroups(tokens),
                  !groups.isEmpty, groups.count <= 3 else { return nil }
            var widthPart: String?
            var stylePart: String?
            var colorPart: String?
            for group in groups {
                if group.count == 1, let w = parseLineWidthToken(group[0]), widthPart == nil {
                    widthPart = w
                } else if group.count == 1, case .ident(let st) = group[0],
                          Self.allowedLineStyles.contains(st.lowercased()), stylePart == nil {
                    stylePart = st.lowercased()
                } else if let c = parseColor(group), colorPart == nil {
                    colorPart = c
                } else {
                    return nil
                }
            }
            var ordered: [String] = []
            if let widthPart { ordered.append(widthPart) }
            if let stylePart { ordered.append(stylePart) }
            if let colorPart { ordered.append(colorPart) }
            return ordered.isEmpty ? nil : ordered.joined(separator: " ")
        }

        private func parseBorderRadius(_ tokens: [CSSToken]) -> String? {
            var slashIndex: Int?
            for (idx, tok) in tokens.enumerated() {
                if case .delim(0x2F) = tok {
                    guard slashIndex == nil else { return nil }
                    slashIndex = idx
                }
            }
            if let slashIndex {
                let left = CSSParser.trimWhitespace(Array(tokens[..<slashIndex]))
                let right = CSSParser.trimWhitespace(Array(tokens[(slashIndex + 1)...]))
                guard let l = parseBoxLengths(left, minCount: 1, maxCount: 4, allowAuto: false, allowNegative: false),
                      let r = parseBoxLengths(right, minCount: 1, maxCount: 4, allowAuto: false, allowNegative: false) else {
                    return nil
                }
                return "\(l) / \(r)"
            }
            return parseBoxLengths(tokens, minCount: 1, maxCount: 4, allowAuto: false, allowNegative: false)
        }

        private func parseTextDecorationLine(_ tokens: [CSSToken]) -> String? {
            if let kw = parseKeyword(tokens, allowed: ["none"]) {
                return kw
            }
            var seen: Set<String> = []
            var ordered: [String] = []
            for token in tokens {
                if case .whitespace = token { continue }
                guard case .ident(let word) = token else { return nil }
                let lower = word.lowercased()
                guard ["underline", "overline", "line-through"].contains(lower),
                      seen.insert(lower).inserted else {
                    return nil
                }
                ordered.append(lower)
            }
            return ordered.isEmpty ? nil : ordered.joined(separator: " ")
        }

        private func parseTextDecoration(_ tokens: [CSSToken]) -> String? {
            if let kw = parseKeyword(tokens, allowed: ["none"]) {
                return kw
            }
            guard let groups = splitColorComponentGroups(tokens), !groups.isEmpty, groups.count <= 5 else { return nil }
            var lines: [String] = []
            var seenLines: Set<String> = []
            var stylePart: String?
            var colorPart: String?
            for group in groups {
                if group.count == 1, case .ident(let word) = group[0] {
                    let lower = word.lowercased()
                    if ["underline", "overline", "line-through"].contains(lower), seenLines.insert(lower).inserted {
                        lines.append(lower)
                        continue
                    }
                    if ["solid", "double", "dotted", "dashed", "wavy"].contains(lower), stylePart == nil {
                        stylePart = lower
                        continue
                    }
                }
                if let c = parseColor(group), colorPart == nil {
                    colorPart = c
                    continue
                }
                return nil
            }
            var parts = lines
            if let stylePart { parts.append(stylePart) }
            if let colorPart { parts.append(colorPart) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        private func parseListStyleShorthand(_ tokens: [CSSToken]) -> String? {
            if let kw = parseKeyword(tokens, allowed: ["none"]) {
                return kw
            }
            var typePart: String?
            var posPart: String?
            for token in tokens {
                if case .whitespace = token { continue }
                guard case .ident(let word) = token else { return nil }
                let lower = word.lowercased()
                if Self.allowedListStyleTypes.contains(lower), typePart == nil {
                    typePart = lower
                } else if ["inside", "outside"].contains(lower), posPart == nil {
                    posPart = lower
                } else {
                    return nil
                }
            }
            var out: [String] = []
            if let typePart { out.append(typePart) }
            if let posPart { out.append(posPart) }
            return out.isEmpty ? nil : out.joined(separator: " ")
        }
    }
}

private func escapeCSSString(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: out.append("\\\"")
        case 0x5C: out.append("\\\\")
        case 0x0A: out.append("\\A ")
        case 0x0D: out.append("\\D ")
        case 0x0C: out.append("\\C ")
        case 0x00...0x1F, 0x7F:
            out.append(String(format: "\\%X ", scalar.value))
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

private func escapeCSSIdentifier(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.utf8.count)
    let scalars = Array(value.unicodeScalars)
    for (idx, scalar) in scalars.enumerated() {
        let v = scalar.value
        let safeASCII = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) ||
            (v >= 0x30 && v <= 0x39 && idx > 0) || v == 0x5F || v == 0x2D
        if safeASCII || v >= 0x80 {
            out.unicodeScalars.append(scalar)
        } else {
            out.append("\\")
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}
