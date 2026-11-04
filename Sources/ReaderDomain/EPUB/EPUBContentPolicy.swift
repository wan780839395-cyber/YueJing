import Foundation

public struct EPUBResolvedLink: Sendable, Equatable {
    public let path: String
    public let fragment: String?

    public init(path: String, fragment: String?) {
        self.path = path
        self.fragment = fragment
    }
}

public struct EPUBSanitizedDocument: Sendable, Equatable {
    public let path: String
    public let xhtmlData: Data
    public let textNodes: [String]
    public let fragmentIDs: Set<String>
    public let referencedImages: Set<String>
    public let referencedLinks: [EPUBResolvedLink]

    public init(
        path: String,
        xhtmlData: Data,
        textNodes: [String],
        fragmentIDs: Set<String>,
        referencedImages: Set<String>,
        referencedLinks: [EPUBResolvedLink]
    ) {
        self.path = path
        self.xhtmlData = xhtmlData
        self.textNodes = textNodes
        self.fragmentIDs = fragmentIDs
        self.referencedImages = referencedImages
        self.referencedLinks = referencedLinks
    }
}

public enum EPUBContentPolicy {
    public static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"
    public static let contentSecurityPolicy =
        "default-src 'none'; script-src 'none'; connect-src 'none'; form-action 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; media-src 'none'; font-src 'none'; img-src yjepub:; style-src 'unsafe-inline'"

    private static let forbiddenElements: Set<String> = [
        "script", "noscript", "svg", "math", "video", "audio", "source", "track",
        "object", "embed", "applet", "param", "iframe", "frame", "frameset", "portal",
        "form", "input", "button", "select", "textarea", "option", "optgroup", "fieldset",
        "canvas", "base", "template", "slot", "dialog"
    ]

    private static let allowedBodyElements: Set<String> = [
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

    private static let voidElements: Set<String> = [
        "br", "hr", "img", "col", "wbr"
    ]

    public static func sanitizeXHTML(
        data: Data,
        path: String,
        manifestByPath: [String: String],
        spineSet: Set<String>,
        destination: URL,
        limits: EPUBLimits = EPUBLimits()
    ) throws -> EPUBSanitizedDocument {
        try Task.checkCancellation()
        let canonicalPath = try EPUBResourcePath.canonical(path)
        let preparedXML = try EPUBXMLSupport.prepareXMLData(data, limit: limits.xhtmlBytes)

        let delegate = XHTMLBuilderDelegate(
            documentPath: canonicalPath,
            manifestByPath: manifestByPath,
            spineSet: spineSet,
            destination: destination,
            limits: limits
        )
        try EPUBXMLSupport.parse(preparedXML, delegate: delegate)
        guard delegate.sawHTML, delegate.sawBody else {
            throw EPUBError.invalidPackage
        }
        guard let bodyRoot = delegate.bodyRoot else {
            throw EPUBError.invalidPackage
        }

        var textNodes: [String] = []
        var bodyMarkup = ""
        serializeChildren(of: bodyRoot, into: &bodyMarkup, textNodes: &textNodes)
        guard !textNodes.isEmpty else {
            throw EPUBError.invalidPackage
        }

        let cleanTitle = delegate.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = cleanTitle.isEmpty ? "Chapter" : cleanTitle
        let bodyAttributes = bodyRoot.attributes.map { " \($0.0)=\"\(escapeXMLAttribute($0.1))\"" }.joined()
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="\(xhtmlNamespace)"><head><meta charset="utf-8"/><meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)"/><title>\(escapeXMLText(effectiveTitle))</title></head><body\(bodyAttributes)>\(bodyMarkup)</body></html>
        """
        let outputData = Data(xhtml.utf8)
        guard outputData.count <= limits.xhtmlBytes else {
            throw EPUBError.limitExceeded
        }

        return EPUBSanitizedDocument(
            path: canonicalPath,
            xhtmlData: outputData,
            textNodes: textNodes,
            fragmentIDs: delegate.fragmentIDs,
            referencedImages: delegate.referencedImages,
            referencedLinks: delegate.referencedLinks
        )
    }

    public static func verifyImageData(_ data: Data, mediaType: String) throws {
        guard !data.isEmpty else { throw EPUBError.corruptResource }
        switch mediaType {
        case "image/png":
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard data.count >= signature.count,
                  Array(data.prefix(signature.count)) == signature else {
                throw EPUBError.corruptResource
            }
        case "image/jpeg":
            let signature: [UInt8] = [0xFF, 0xD8, 0xFF]
            guard data.count >= signature.count,
                  Array(data.prefix(signature.count)) == signature else {
                throw EPUBError.corruptResource
            }
        default:
            throw EPUBError.unsupportedContent
        }
    }

    public static func escapeXMLText(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\r": out.append("&#13;")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func escapeXMLAttribute(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            case "\r": out.append("&#13;")
            case "\n": out.append("&#10;")
            case "\t": out.append("&#9;")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    fileprivate final class DOMElement {
        let name: String
        let attributes: [(String, String)]
        var children: [DOMNode] = []

        init(name: String, attributes: [(String, String)]) {
            self.name = name
            self.attributes = attributes
        }
    }

    fileprivate enum DOMNode {
        case element(DOMElement)
        case text(String)
    }

    private static func serializeChildren(
        of parent: DOMElement,
        into output: inout String,
        textNodes: inout [String]
    ) {
        for child in parent.children {
            switch child {
            case .text(let raw):
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if raw.contains(" ") {
                        output.append(" ")
                    }
                } else {
                    let index = textNodes.count
                    textNodes.append(raw)
                    output.append("<span id=\"yj-t\(index)\">")
                    output.append(escapeXMLText(raw))
                    output.append("</span>")
                }
            case .element(let elem):
                output.append("<")
                output.append(elem.name)
                for (key, value) in elem.attributes {
                    output.append(" ")
                    output.append(key)
                    output.append("=\"")
                    output.append(escapeXMLAttribute(value))
                    output.append("\"")
                }
                if voidElements.contains(elem.name) {
                    output.append("/>")
                } else {
                    output.append(">")
                    serializeChildren(of: elem, into: &output, textNodes: &textNodes)
                    output.append("</")
                    output.append(elem.name)
                    output.append(">")
                }
            }
        }
    }

    private final class XHTMLBuilderDelegate: EPUBXMLBaseDelegate {
        let documentPath: String
        let manifestByPath: [String: String]
        let spineSet: Set<String>
        let destination: URL
        let limits: EPUBLimits

        var sawHTML = false
        var sawBody = false
        var inHead = false
        var inBody = false
        var inTitle = false
        var ignoredStyleDepth = 0
        var currentStyleText = ""
        var titleText = ""
        var pendingText = ""

        var bodyRoot: DOMElement?
        var elementStack: [DOMElement] = []
        var fragmentIDs: Set<String> = []
        var referencedImages: Set<String> = []
        var referencedLinks: [EPUBResolvedLink] = []

        init(
            documentPath: String,
            manifestByPath: [String: String],
            spineSet: Set<String>,
            destination: URL,
            limits: EPUBLimits
        ) {
            self.documentPath = documentPath
            self.manifestByPath = manifestByPath
            self.spineSet = spineSet
            self.destination = destination
            self.limits = limits
        }

        private func flushPendingText() {
            guard !pendingText.isEmpty else { return }
            let text = pendingText
            pendingText = ""
            if inBody, ignoredStyleDepth == 0, let current = elementStack.last, !voidElements.contains(current.name) {
                current.children.append(.text(text))
            }
        }

        override func handleStartElement(
            name: String,
            localName: String,
            prefix: String?,
            attributes: [String: String],
            parser: XMLParser
        ) throws {
            flushPendingText()
            let lowerLocal = localName.lowercased()
            let lowerPrefix = prefix?.lowercased()

            if lowerPrefix == "svg" || lowerPrefix == "math" {
                throw EPUBError.unsupportedContent
            }
            if let xmlns = attributes["xmlns"], xmlns != xhtmlNamespace {
                throw EPUBError.unsupportedContent
            }
            for (attrName, attrValue) in attributes {
                let lowerAttr = attrName.lowercased()
                if lowerAttr.hasPrefix("on") {
                    throw EPUBError.unsupportedContent
                }
                if lowerAttr == "xmlns:svg" || lowerAttr == "xmlns:math" ||
                    attrValue == "http://www.w3.org/2000/svg" ||
                    attrValue == "http://www.w3.org/1998/Math/MathML" {
                    throw EPUBError.unsupportedContent
                }
                if lowerAttr == "srcdoc" || lowerAttr == "formaction" || lowerAttr == "xlink:href" {
                    throw EPUBError.unsupportedContent
                }
                if lowerAttr == "style" {
                    try validateInlineStyleAttribute(attrValue)
                }
            }

            if forbiddenElements.contains(lowerLocal) {
                throw EPUBError.unsupportedContent
            }

            if lowerLocal == "html" {
                guard !sawHTML, elementStack.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                sawHTML = true
                return
            }

            guard sawHTML else {
                throw EPUBError.invalidPackage
            }

            if lowerLocal == "head" {
                guard !inHead, !inBody, !sawBody else {
                    throw EPUBError.invalidPackage
                }
                inHead = true
                return
            }

            if inHead {
                if lowerLocal == "title" {
                    inTitle = true
                } else if lowerLocal == "style" {
                    ignoredStyleDepth += 1
                    currentStyleText = ""
                } else if lowerLocal == "meta" {
                    if let httpEquiv = attributeValue(attributes, named: "http-equiv")?.lowercased(),
                       httpEquiv == "refresh" {
                        throw EPUBError.unsupportedContent
                    }
                } else if lowerLocal == "link" {
                    try validateHeadLink(attributes)
                } else {
                    throw EPUBError.unsupportedContent
                }
                return
            }

            if lowerLocal == "body" {
                guard !inBody, !sawBody else {
                    throw EPUBError.invalidPackage
                }
                sawBody = true
                inBody = true
                let bodyID = try extractAndRecordID(from: attributes)
                let root = DOMElement(name: "body", attributes: bodyID.map { [("id", $0)] } ?? [])
                bodyRoot = root
                elementStack = [root]
                return
            }

            guard inBody else {
                throw EPUBError.invalidPackage
            }

            if ignoredStyleDepth > 0 {
                if lowerLocal == "style" {
                    ignoredStyleDepth += 1
                } else {
                    throw EPUBError.unsupportedContent
                }
                return
            }

            if lowerLocal == "style" {
                ignoredStyleDepth = 1
                currentStyleText = ""
                return
            }

            guard allowedBodyElements.contains(lowerLocal) else {
                throw EPUBError.unsupportedContent
            }

            var sanitizedAttrs: [(String, String)] = []
            if let id = try extractAndRecordID(from: attributes) {
                sanitizedAttrs.append(("id", id))
            }

            if lowerLocal == "img" {
                guard let rawSrc = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawSrc.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                try rejectActiveOrExternalScheme(rawSrc)
                let resolved = try EPUBResourcePath.resolve(rawSrc, relativeTo: documentPath)
                guard resolved.fragment == nil else {
                    throw EPUBError.invalidPackage
                }
                guard let mediaType = manifestByPath[resolved.path] else {
                    throw EPUBError.invalidPackage
                }
                guard mediaType == "image/jpeg" || mediaType == "image/png" else {
                    throw EPUBError.unsupportedContent
                }
                try validateExtractedImage(at: resolved.path, mediaType: mediaType)
                referencedImages.insert(resolved.path)

                let relSrc = EPUBResourcePath.relativeHref(from: documentPath, to: resolved.path)
                sanitizedAttrs.append(("src", relSrc))
                sanitizedAttrs.append(("alt", attributes["alt"] ?? ""))
            } else if lowerLocal == "a" {
                if let rawHref = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    guard !rawHref.isEmpty else {
                        throw EPUBError.invalidPackage
                    }
                    try rejectActiveOrExternalScheme(rawHref)
                    let resolved = try EPUBResourcePath.resolve(rawHref, relativeTo: documentPath)
                    guard spineSet.contains(resolved.path) else {
                        throw EPUBError.invalidPackage
                    }
                    referencedLinks.append(EPUBResolvedLink(path: resolved.path, fragment: resolved.fragment))
                    let relHref: String
                    if resolved.path == documentPath, let frag = resolved.fragment {
                        relHref = "#" + frag
                    } else {
                        relHref = EPUBResourcePath.relativeHref(from: documentPath, to: resolved.path, fragment: resolved.fragment)
                    }
                    sanitizedAttrs.append(("href", relHref))
                }
            }

            if let dir = attributes["dir"], ["ltr", "rtl", "auto"].contains(dir.lowercased()) {
                sanitizedAttrs.append(("dir", dir.lowercased()))
            }

            let element = DOMElement(name: lowerLocal, attributes: sanitizedAttrs)
            guard let parent = elementStack.last, !voidElements.contains(parent.name) else {
                throw EPUBError.invalidPackage
            }
            parent.children.append(.element(element))
            elementStack.append(element)
        }

        override func handleEndElement(name: String, localName: String, prefix: String?, parser: XMLParser) throws {
            flushPendingText()
            let lowerLocal = localName.lowercased()

            if lowerLocal == "html" {
                return
            }
            if inHead {
                if lowerLocal == "title" {
                    inTitle = false
                } else if lowerLocal == "style" {
                    try validateStyleContent(currentStyleText)
                    currentStyleText = ""
                    ignoredStyleDepth = max(0, ignoredStyleDepth - 1)
                } else if lowerLocal == "head" {
                    inHead = false
                }
                return
            }
            if inBody {
                if ignoredStyleDepth > 0 {
                    if lowerLocal == "style" {
                        try validateStyleContent(currentStyleText)
                        currentStyleText = ""
                        ignoredStyleDepth -= 1
                    }
                    return
                }
                if lowerLocal == "body" {
                    guard elementStack.count == 1 else {
                        throw EPUBError.invalidPackage
                    }
                    elementStack.removeLast()
                    inBody = false
                    return
                }
                guard let popped = elementStack.popLast(), popped.name == lowerLocal else {
                    throw EPUBError.invalidPackage
                }
            }
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            if ignoredStyleDepth > 0 {
                currentStyleText.append(string)
            } else if inTitle {
                titleText.append(string)
            } else if inBody {
                pendingText.append(string)
            }
        }

        private func extractAndRecordID(from attributes: [String: String]) throws -> String? {
            let rawID = attributes["id"]
            let rawXMLID = attributes["xml:id"]
            if let rawID, let rawXMLID, rawID != rawXMLID {
                throw EPUBError.invalidPackage
            }
            guard let candidate = rawID ?? rawXMLID else {
                return nil
            }
            let normalized = candidate.precomposedStringWithCanonicalMapping
            guard EPUBResourcePath.isValidFragmentID(normalized),
                  !normalized.lowercased().hasPrefix("yj-t") else {
                throw EPUBError.invalidPackage
            }
            guard fragmentIDs.insert(normalized).inserted else {
                throw EPUBError.invalidPackage
            }
            return normalized
        }

        private func rejectActiveOrExternalScheme(_ rawURI: String) throws {
            let lower = rawURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:") {
                throw EPUBError.unsupportedContent
            }
            if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("file:") ||
                lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") || lower.hasPrefix("yjepub:") ||
                lower.hasPrefix("//") {
                throw EPUBError.unsupportedContent
            }
        }

        private func validateHeadLink(_ attributes: [String: String]) throws {
            let rel = (attributeValue(attributes, named: "rel") ?? "").lowercased()
            let type = (attributeValue(attributes, named: "type") ?? "").lowercased()
            let href = (attributeValue(attributes, named: "href") ?? "").lowercased()
            if rel.contains("font") || type.contains("font") || type.contains("javascript") ||
                href.hasSuffix(".ttf") || href.hasSuffix(".otf") ||
                href.hasSuffix(".woff") || href.hasSuffix(".woff2") {
                throw EPUBError.unsupportedContent
            }
            if href.hasPrefix("http:") || href.hasPrefix("https:") || href.hasPrefix("//") ||
                href.hasPrefix("javascript:") || href.hasPrefix("data:") {
                throw EPUBError.unsupportedContent
            }
        }

        private func validateStyleContent(_ css: String) throws {
            let lower = css.lowercased()
            if lower.contains("@font-face") || lower.contains("javascript:") || lower.contains("expression(") ||
                lower.contains(".woff") || lower.contains(".ttf") || lower.contains(".otf") ||
                lower.contains("http://") || lower.contains("https://") {
                throw EPUBError.unsupportedContent
            }
        }

        private func validateInlineStyleAttribute(_ style: String) throws {
            let lower = style.lowercased()
            if lower.contains("url(") || lower.contains("@import") || lower.contains("@font-face") ||
                lower.contains("javascript:") || lower.contains("expression(") {
                throw EPUBError.unsupportedContent
            }
        }

        private func validateExtractedImage(at canonicalPath: String, mediaType: String) throws {
            var fileURL = destination
            for segment in canonicalPath.split(separator: "/") {
                fileURL.appendPathComponent(String(segment))
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw EPUBError.invalidPackage
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw EPUBError.unsafePath
            }
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw EPUBError.corruptResource
            }
            guard size <= limits.imageBytes else {
                throw EPUBError.limitExceeded
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            try verifyImageData(header, mediaType: mediaType)
        }

        private func attributeValue(_ attributes: [String: String], named target: String) -> String? {
            if let exact = attributes[target] { return exact }
            let lower = target.lowercased()
            return attributes.first { $0.key.lowercased() == lower }?.value
        }
    }
}

enum EPUBXMLSupport {
    static func prepareXMLData(_ rawData: Data, limit: Int) throws -> Data {
        try Task.checkCancellation()
        guard !rawData.isEmpty else {
            throw EPUBError.invalidPackage
        }
        guard rawData.count <= limit else {
            throw EPUBError.limitExceeded
        }

        guard let decoded = decodeStrictXMLString(rawData) else {
            throw EPUBError.invalidPackage
        }
        try validateXMLCharactersAndProlog(in: decoded)
        let normalized = normalizeXMLDeclaration(in: decoded)
        return Data(normalized.utf8)
    }

    static func parse(_ xmlData: Data, delegate: EPUBXMLBaseDelegate) throws {
        try Task.checkCancellation()
        let parser = XMLParser(data: xmlData)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let error = delegate.failure {
            throw error
        }
        guard ok, parser.parserError == nil else {
            throw EPUBError.invalidPackage
        }
    }

    static func localName(of rawName: String) -> String {
        if let colon = rawName.lastIndex(of: ":") {
            return String(rawName[rawName.index(after: colon)...])
        }
        return rawName
    }

    static func prefix(of rawName: String) -> String? {
        if let colon = rawName.firstIndex(of: ":") {
            return String(rawName[..<colon])
        }
        return nil
    }

    private static func decodeStrictXMLString(_ rawData: Data) -> String? {
        if rawData.count >= 4 {
            let b0 = rawData[rawData.startIndex]
            let b1 = rawData[rawData.startIndex + 1]
            let b2 = rawData[rawData.startIndex + 2]
            let b3 = rawData[rawData.startIndex + 3]
            if (b0 == 0xFF && b1 == 0xFE && b2 == 0x00 && b3 == 0x00) ||
                (b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF) {
                return nil
            }
        }
        if rawData.starts(with: [0xEF, 0xBB, 0xBF]) {
            return decodeStrictUTF8(rawData.dropFirst(3))
        }
        if rawData.starts(with: [0xFE, 0xFF]) {
            return decodeStrictUTF16(rawData.dropFirst(2), bigEndian: true)
        }
        if rawData.starts(with: [0xFF, 0xFE]) {
            return decodeStrictUTF16(rawData.dropFirst(2), bigEndian: false)
        }
        if rawData.count >= 4 {
            let b0 = rawData[rawData.startIndex]
            let b1 = rawData[rawData.startIndex + 1]
            let b2 = rawData[rawData.startIndex + 2]
            let b3 = rawData[rawData.startIndex + 3]
            if b0 == 0x00 && b1 == 0x3C && b2 == 0x00 {
                return decodeStrictUTF16(rawData[...], bigEndian: true)
            }
            if b0 == 0x3C && b1 == 0x00 && b3 == 0x00 {
                return decodeStrictUTF16(rawData[...], bigEndian: false)
            }
        }
        return decodeStrictUTF8(rawData[...])
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

    private static func validateXMLCharactersAndProlog(in xml: String) throws {
        for scalar in xml.unicodeScalars {
            let v = scalar.value
            let valid = (v == 0x09 || v == 0x0A || v == 0x0D) ||
                (v >= 0x20 && v <= 0xD7FF) ||
                (v >= 0xE000 && v <= 0xFFFD) ||
                (v >= 0x10000 && v <= 0x10FFFF)
            if !valid {
                throw EPUBError.invalidPackage
            }
        }

        let lower = xml.lowercased()
        if lower.contains("<!doctype") ||
            lower.contains("<!entity") ||
            lower.contains("<!element") ||
            lower.contains("<!attlist") ||
            lower.contains("<!notation") ||
            lower.contains("http://www.w3.org/2001/xinclude") ||
            lower.contains("xi:include") {
            throw EPUBError.invalidPackage
        }
    }

    private static func normalizeXMLDeclaration(in xml: String) -> String {
        let trimmed = xml.drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
        guard trimmed.hasPrefix("<?xml") else {
            return xml
        }
        guard let endRange = trimmed.range(of: "?>") else {
            return xml
        }
        let remainder = trimmed[endRange.upperBound...]
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + String(remainder)
    }
}

class EPUBXMLBaseDelegate: NSObject, XMLParserDelegate {
    var failure: Error?
    private var elementDepth = 0
    private var elementCount = 0

    func fail(_ error: Error, parser: XMLParser) {
        if failure == nil {
            failure = error
        }
        parser.abortParsing()
    }

    func handleStartElement(
        name: String,
        localName: String,
        prefix: String?,
        attributes: [String: String],
        parser: XMLParser
    ) throws {}

    func handleEndElement(
        name: String,
        localName: String,
        prefix: String?,
        parser: XMLParser
    ) throws {}

    func handleCharacters(_ string: String, parser: XMLParser) throws {}

    final func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        do {
            try Task.checkCancellation()
            elementDepth += 1
            elementCount += 1
            guard elementDepth <= 128, elementCount <= 250_000 else { throw EPUBError.limitExceeded }
            let local = EPUBXMLSupport.localName(of: elementName)
            let pref = EPUBXMLSupport.prefix(of: elementName)
            try handleStartElement(
                name: elementName,
                localName: local,
                prefix: pref,
                attributes: attributeDict,
                parser: parser
            )
        } catch {
            fail(error, parser: parser)
        }
    }

    final func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        do {
            try Task.checkCancellation()
            let local = EPUBXMLSupport.localName(of: elementName)
            let pref = EPUBXMLSupport.prefix(of: elementName)
            try handleEndElement(name: elementName, localName: local, prefix: pref, parser: parser)
            elementDepth -= 1
        } catch {
            fail(error, parser: parser)
        }
    }

    final func parser(_ parser: XMLParser, foundCharacters string: String) {
        do {
            try Task.checkCancellation()
            try handleCharacters(string, parser: parser)
        } catch {
            fail(error, parser: parser)
        }
    }

    final func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            fail(EPUBError.invalidPackage, parser: parser)
            return
        }
        self.parser(parser, foundCharacters: text)
    }

    final func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?,
        notationName: String?
    ) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        foundNotationDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        foundElementDeclarationWithName elementName: String,
        model: String
    ) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        foundAttributeDeclarationWithName attributeName: String,
        forElement elementName: String,
        type: String?,
        defaultValue: String?
    ) {
        fail(EPUBError.invalidPackage, parser: parser)
    }

    final func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(EPUBError.invalidPackage, parser: parser)
        return nil
    }
}
