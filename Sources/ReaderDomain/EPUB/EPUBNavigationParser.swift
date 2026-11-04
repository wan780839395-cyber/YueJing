import Foundation

public enum EPUBNavigationParser {
    public static func parseNavigationDocument(
        data: Data,
        navPath: String,
        spineSet: Set<String>,
        fragmentIDsByPath: [String: Set<String>],
        limits: EPUBLimits = EPUBLimits()
    ) throws -> [EPUBNavigationItem] {
        try Task.checkCancellation()
        let canonicalNavPath = try EPUBResourcePath.canonical(navPath)
        let xmlData = try EPUBXMLSupport.prepareXMLData(data, limit: min(limits.xmlBytes, limits.xhtmlBytes))
        let delegate = NavDocumentDelegate(
            navPath: canonicalNavPath,
            spineSet: spineSet,
            fragmentIDsByPath: fragmentIDsByPath
        )
        try EPUBXMLSupport.parse(xmlData, delegate: delegate)
        let selected = delegate.tocItems.isEmpty ? delegate.fallbackItems : delegate.tocItems
        guard delegate.sawHTML, !selected.isEmpty else {
            throw EPUBError.invalidPackage
        }
        return selected
    }

    public static func parseNCX(
        data: Data,
        ncxPath: String,
        spineSet: Set<String>,
        fragmentIDsByPath: [String: Set<String>],
        limits: EPUBLimits = EPUBLimits()
    ) throws -> [EPUBNavigationItem] {
        try Task.checkCancellation()
        let canonicalNCXPath = try EPUBResourcePath.canonical(ncxPath)
        let xmlData = try EPUBXMLSupport.prepareXMLData(data, limit: limits.xmlBytes)
        let delegate = NCXDocumentDelegate(
            ncxPath: canonicalNCXPath,
            spineSet: spineSet,
            fragmentIDsByPath: fragmentIDsByPath
        )
        try EPUBXMLSupport.parse(xmlData, delegate: delegate)
        guard delegate.sawNCX, delegate.sawNavMap, !delegate.items.isEmpty else {
            throw EPUBError.invalidPackage
        }
        return delegate.items
    }

    fileprivate static func normalizeTitle(_ raw: String) -> String {
        let parts = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    fileprivate static func validateTarget(
        href: String,
        basePath: String,
        spineSet: Set<String>,
        fragmentIDsByPath: [String: Set<String>]
    ) throws -> (path: String, fragment: String?) {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EPUBError.invalidPackage
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("vbscript:") {
            throw EPUBError.unsupportedContent
        }
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("file:") || lower.hasPrefix("//") {
            throw EPUBError.invalidPackage
        }
        let resolved: (path: String, fragment: String?)
        do {
            resolved = try EPUBResourcePath.resolve(trimmed, relativeTo: basePath)
        } catch {
            throw EPUBError.invalidPackage
        }
        guard spineSet.contains(resolved.path) else {
            throw EPUBError.invalidPackage
        }
        if let fragment = resolved.fragment {
            guard fragmentIDsByPath[resolved.path]?.contains(fragment) == true else {
                throw EPUBError.invalidPackage
            }
        }
        return resolved
    }

    private final class NavDocumentDelegate: EPUBXMLBaseDelegate {
        let navPath: String
        let spineSet: Set<String>
        let fragmentIDsByPath: [String: Set<String>]

        var sawHTML = false
        var tocItems: [EPUBNavigationItem] = []
        var fallbackItems: [EPUBNavigationItem] = []

        private enum NavTargetKind {
            case toc
            case fallback
            case ignored
        }

        private var activeNavKind: NavTargetKind?
        private var navElementDepth = 0
        private var sawFallbackNav = false
        private var listDepth = 0

        private struct LIContext {
            let depth: Int
            var capturedLink: Bool = false
        }
        private var liStack: [LIContext] = []
        private var activeAnchorHref: String?
        private var activeAnchorText = ""
        private var activeAnchorDepth = 0

        init(navPath: String, spineSet: Set<String>, fragmentIDsByPath: [String: Set<String>]) {
            self.navPath = navPath
            self.spineSet = spineSet
            self.fragmentIDsByPath = fragmentIDsByPath
        }

        override func handleStartElement(
            name: String,
            localName: String,
            prefix: String?,
            attributes: [String: String],
            parser: XMLParser
        ) throws {
            let lower = localName.lowercased()
            if lower == "script" || lower == "svg" || lower == "math" || lower == "iframe" || lower == "object" {
                throw EPUBError.unsupportedContent
            }
            if lower == "html" {
                sawHTML = true
                return
            }

            if activeNavKind != nil {
                navElementDepth += 1
                if lower == "ol" || lower == "ul" {
                    listDepth += 1
                } else if lower == "li" {
                    guard listDepth > 0 else {
                        throw EPUBError.invalidPackage
                    }
                    liStack.append(LIContext(depth: listDepth - 1))
                } else if lower == "a" {
                    if let currentLI = liStack.last, !currentLI.capturedLink, activeAnchorHref == nil {
                        guard let href = attributes["href"] else {
                            throw EPUBError.invalidPackage
                        }
                        activeAnchorHref = href
                        activeAnchorText = ""
                        activeAnchorDepth = currentLI.depth
                    }
                }
                return
            }

            if lower == "nav" {
                navElementDepth = 1
                listDepth = 0
                liStack.removeAll()
                let typeTokens = navTypeTokens(from: attributes)
                if typeTokens.contains("toc") {
                    activeNavKind = .toc
                } else if typeTokens.isEmpty && !sawFallbackNav {
                    sawFallbackNav = true
                    activeNavKind = .fallback
                } else {
                    activeNavKind = .ignored
                }
            }
        }

        override func handleEndElement(
            name: String,
            localName: String,
            prefix: String?,
            parser: XMLParser
        ) throws {
            guard let kind = activeNavKind else { return }
            let lower = localName.lowercased()

            if lower == "a", let rawHref = activeAnchorHref {
                activeAnchorHref = nil
                let title = EPUBNavigationParser.normalizeTitle(activeAnchorText)
                activeAnchorText = ""
                guard !title.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                if !liStack.isEmpty {
                    liStack[liStack.count - 1].capturedLink = true
                }
                if kind == .toc || kind == .fallback {
                    let resolved = try EPUBNavigationParser.validateTarget(
                        href: rawHref,
                        basePath: navPath,
                        spineSet: spineSet,
                        fragmentIDsByPath: fragmentIDsByPath
                    )
                    let item = EPUBNavigationItem(
                        title: title,
                        path: resolved.path,
                        fragment: resolved.fragment,
                        depth: activeAnchorDepth
                    )
                    if kind == .toc {
                        tocItems.append(item)
                    } else {
                        fallbackItems.append(item)
                    }
                }
            } else if lower == "li" {
                _ = liStack.popLast()
            } else if lower == "ol" || lower == "ul" {
                listDepth = max(0, listDepth - 1)
            }

            navElementDepth -= 1
            if navElementDepth == 0 {
                activeNavKind = nil
                listDepth = 0
                liStack.removeAll()
            }
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            if activeAnchorHref != nil {
                activeAnchorText.append(string)
            }
        }

        private func navTypeTokens(from attributes: [String: String]) -> Set<String> {
            for (key, value) in attributes {
                let lowerKey = key.lowercased()
                if lowerKey == "epub:type" || lowerKey.hasSuffix(":type") || lowerKey == "type" || lowerKey == "role" {
                    let tokens = value.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    return Set(tokens)
                }
            }
            return []
        }
    }

    private final class NCXDocumentDelegate: EPUBXMLBaseDelegate {
        let ncxPath: String
        let spineSet: Set<String>
        let fragmentIDsByPath: [String: Set<String>]

        var sawNCX = false
        var sawNavMap = false
        var items: [EPUBNavigationItem] = []

        private struct NavPointState {
            let depth: Int
            var label: String = ""
            var src: String?
            var emitted: Bool = false
        }

        private var inNavMap = false
        private var navPointStack: [NavPointState] = []
        private var inNavLabel = false
        private var inText = false
        private var currentText = ""

        init(ncxPath: String, spineSet: Set<String>, fragmentIDsByPath: [String: Set<String>]) {
            self.ncxPath = ncxPath
            self.spineSet = spineSet
            self.fragmentIDsByPath = fragmentIDsByPath
        }

        private func emitIfReady(at index: Int) throws {
            guard navPointStack.indices.contains(index), !navPointStack[index].emitted else { return }
            let state = navPointStack[index]
            let title = EPUBNavigationParser.normalizeTitle(state.label)
            guard let rawSrc = state.src, !title.isEmpty else {
                throw EPUBError.invalidPackage
            }
            let resolved = try EPUBNavigationParser.validateTarget(
                href: rawSrc,
                basePath: ncxPath,
                spineSet: spineSet,
                fragmentIDsByPath: fragmentIDsByPath
            )
            items.append(
                EPUBNavigationItem(
                    title: title,
                    path: resolved.path,
                    fragment: resolved.fragment,
                    depth: state.depth
                )
            )
            navPointStack[index].emitted = true
        }

        override func handleStartElement(
            name: String,
            localName: String,
            prefix: String?,
            attributes: [String: String],
            parser: XMLParser
        ) throws {
            let lower = localName.lowercased()
            if lower == "ncx" {
                sawNCX = true
                return
            }
            if lower == "navmap" {
                guard sawNCX, !inNavMap else {
                    throw EPUBError.invalidPackage
                }
                sawNavMap = true
                inNavMap = true
                return
            }
            guard inNavMap else { return }

            if lower == "navpoint" {
                if !navPointStack.isEmpty {
                    try emitIfReady(at: navPointStack.count - 1)
                }
                navPointStack.append(NavPointState(depth: navPointStack.count))
            } else if lower == "navlabel" {
                guard !navPointStack.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                inNavLabel = true
            } else if lower == "text", inNavLabel {
                inText = true
                currentText = ""
            } else if lower == "content" {
                guard !navPointStack.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                let idx = navPointStack.count - 1
                if navPointStack[idx].src == nil {
                    guard let src = attributes["src"], !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw EPUBError.invalidPackage
                    }
                    navPointStack[idx].src = src
                    if !navPointStack[idx].label.isEmpty {
                        try emitIfReady(at: idx)
                    }
                }
            }
        }

        override func handleEndElement(
            name: String,
            localName: String,
            prefix: String?,
            parser: XMLParser
        ) throws {
            let lower = localName.lowercased()
            if lower == "navmap" {
                guard navPointStack.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                inNavMap = false
                return
            }
            guard inNavMap else { return }

            if lower == "text", inText {
                inText = false
                if !navPointStack.isEmpty {
                    let idx = navPointStack.count - 1
                    if navPointStack[idx].label.isEmpty {
                        navPointStack[idx].label = EPUBNavigationParser.normalizeTitle(currentText)
                    }
                }
                currentText = ""
            } else if lower == "navlabel" {
                inNavLabel = false
            } else if lower == "navpoint" {
                guard !navPointStack.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                let idx = navPointStack.count - 1
                try emitIfReady(at: idx)
                navPointStack.removeLast()
            }
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            if inText {
                currentText.append(string)
            }
        }
    }
}
