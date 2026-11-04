import Foundation

public enum EPUBPackageParser {
    public static func parse(
        archiveURL: URL,
        destination: URL,
        limits: EPUBLimits = EPUBLimits()
    ) throws -> EPUBPackage {
        try Task.checkCancellation()
        guard limits.spineItems > 0 else {
            throw EPUBError.limitExceeded
        }

        let extraction = try EPUBArchive.extract(archiveURL: archiveURL, to: destination, limits: limits)
        do {
            for path in extraction.entries.keys {
                let lower = path.lowercased()
                if lower == "meta-inf/encryption.xml" || lower == "meta-inf/rights.xml" {
                    throw EPUBError.unsupportedContent
                }
            }

            guard let mimetypeEntry = extraction.entries["mimetype"],
                  mimetypeEntry.byteCount == 20, mimetypeEntry.compressionMethod == 0 else {
                throw EPUBError.invalidArchive
            }
            let mimeData = try readExtractedFile(at: "mimetype", under: destination, expectedSize: mimetypeEntry.byteCount)
            guard mimeData == Data("application/epub+zip".utf8) else { throw EPUBError.invalidArchive }

            guard let containerEntry = extraction.entries["META-INF/container.xml"] else {
                throw EPUBError.invalidPackage
            }
            guard containerEntry.byteCount <= limits.xmlBytes else {
                throw EPUBError.limitExceeded
            }
            let containerData = try readExtractedFile(
                at: "META-INF/container.xml",
                under: destination,
                expectedSize: containerEntry.byteCount
            )
            let opfPath = try parseContainer(containerData, limits: limits)

            guard let opfEntry = extraction.entries[opfPath] else {
                throw EPUBError.invalidPackage
            }
            guard opfEntry.byteCount <= limits.xmlBytes else {
                throw EPUBError.limitExceeded
            }
            let opfData = try readExtractedFile(at: opfPath, under: destination, expectedSize: opfEntry.byteCount)
            let opf = try parseOPF(opfData, opfPath: opfPath, limits: limits)

            let title = opf.title
            guard !title.isEmpty, !opf.spineIDRefs.isEmpty else {
                throw EPUBError.invalidPackage
            }
            guard opf.spineIDRefs.count <= limits.spineItems else {
                throw EPUBError.limitExceeded
            }

            var manifestByID: [String: ManifestItem] = [:]
            var manifestByPath: [String: ManifestItem] = [:]
            var manifestMediaTypesByPath: [String: String] = [:]
            for item in opf.manifestItems {
                manifestByID[item.id] = item
                manifestByPath[item.path] = item
                manifestMediaTypesByPath[item.path] = item.mediaType
            }

            var spinePaths: [String] = []
            spinePaths.reserveCapacity(opf.spineIDRefs.count)
            var spineSet: Set<String> = []
            for idref in opf.spineIDRefs {
                guard let item = manifestByID[idref] else {
                    throw EPUBError.invalidPackage
                }
                if item.properties.contains("svg") ||
                    item.properties.contains("mathml") ||
                    item.properties.contains("scripted") ||
                    item.properties.contains("remote-resources") ||
                    item.properties.contains("rendition:layout-pre-paginated") ||
                    item.properties.contains("layout-pre-paginated") {
                    throw EPUBError.unsupportedContent
                }
                guard item.mediaType == "application/xhtml+xml" else {
                    throw EPUBError.unsupportedContent
                }
                guard extraction.entries[item.path] != nil else {
                    throw EPUBError.invalidPackage
                }
                guard spineSet.insert(item.path).inserted else {
                    throw EPUBError.invalidPackage
                }
                spinePaths.append(item.path)
            }

            let navCandidates = opf.manifestItems.filter { $0.properties.contains("nav") }
            guard navCandidates.count <= 1 else {
                throw EPUBError.invalidPackage
            }
            let navItem = navCandidates.first
            var rawNavData: Data?
            if let navItem {
                guard navItem.mediaType == "application/xhtml+xml",
                      let navEntry = extraction.entries[navItem.path] else {
                    throw EPUBError.invalidPackage
                }
                guard navEntry.byteCount <= min(limits.xmlBytes, limits.xhtmlBytes) else {
                    throw EPUBError.limitExceeded
                }
                rawNavData = try readExtractedFile(at: navItem.path, under: destination, expectedSize: navEntry.byteCount)
            }

            var sanitizedByPath: [String: EPUBSanitizedDocument] = [:]
            var fragmentIDsByPath: [String: Set<String>] = [:]
            var textNodesByPath: [String: [String]] = [:]
            var referencedBodyImages: Set<String> = []

            for spinePath in spinePaths {
                try Task.checkCancellation()
                guard let spineEntry = extraction.entries[spinePath] else {
                    throw EPUBError.invalidPackage
                }
                guard spineEntry.byteCount <= limits.xhtmlBytes else {
                    throw EPUBError.limitExceeded
                }
                let rawXHTML = try readExtractedFile(at: spinePath, under: destination, expectedSize: spineEntry.byteCount)
                let sanitized = try EPUBContentPolicy.sanitizeXHTML(
                    data: rawXHTML,
                    path: spinePath,
                    manifestByPath: manifestMediaTypesByPath,
                    spineSet: spineSet,
                    destination: destination,
                    limits: limits
                )
                sanitizedByPath[spinePath] = sanitized
                fragmentIDsByPath[spinePath] = sanitized.fragmentIDs
                textNodesByPath[spinePath] = sanitized.textNodes
                referencedBodyImages.formUnion(sanitized.referencedImages)
            }

            for spinePath in spinePaths {
                guard let sanitized = sanitizedByPath[spinePath] else {
                    throw EPUBError.invalidPackage
                }
                for link in sanitized.referencedLinks {
                    guard spineSet.contains(link.path) else {
                        throw EPUBError.invalidPackage
                    }
                    if let fragment = link.fragment {
                        guard fragmentIDsByPath[link.path]?.contains(fragment) == true else {
                            throw EPUBError.invalidPackage
                        }
                    }
                }
            }

            if let tocID = opf.spineTOCID {
                guard !tocID.isEmpty,
                      let ncxItem = manifestByID[tocID],
                      ncxItem.mediaType == "application/x-dtbncx+xml",
                      extraction.entries[ncxItem.path] != nil else {
                    throw EPUBError.invalidPackage
                }
            }

            let navigation: [EPUBNavigationItem]
            if let navItem, let rawNavData {
                navigation = try EPUBNavigationParser.parseNavigationDocument(
                    data: rawNavData,
                    navPath: navItem.path,
                    spineSet: spineSet,
                    fragmentIDsByPath: fragmentIDsByPath,
                    limits: limits
                )
                if let tocID = opf.spineTOCID, let ncxItem = manifestByID[tocID],
                   let ncxEntry = extraction.entries[ncxItem.path] {
                    guard ncxEntry.byteCount <= limits.xmlBytes else {
                        throw EPUBError.limitExceeded
                    }
                    let ncxData = try readExtractedFile(at: ncxItem.path, under: destination, expectedSize: ncxEntry.byteCount)
                    _ = try EPUBNavigationParser.parseNCX(
                        data: ncxData,
                        ncxPath: ncxItem.path,
                        spineSet: spineSet,
                        fragmentIDsByPath: fragmentIDsByPath,
                        limits: limits
                    )
                }
            } else if let ncxItem = (opf.spineTOCID.flatMap { manifestByID[$0] })
                        ?? opf.manifestItems.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
                guard let ncxEntry = extraction.entries[ncxItem.path] else {
                    throw EPUBError.invalidPackage
                }
                guard ncxEntry.byteCount <= limits.xmlBytes else {
                    throw EPUBError.limitExceeded
                }
                let ncxData = try readExtractedFile(at: ncxItem.path, under: destination, expectedSize: ncxEntry.byteCount)
                navigation = try EPUBNavigationParser.parseNCX(
                    data: ncxData,
                    ncxPath: ncxItem.path,
                    spineSet: spineSet,
                    fragmentIDsByPath: fragmentIDsByPath,
                    limits: limits
                )
            } else {
                navigation = spinePaths.enumerated().map { index, path in
                    EPUBNavigationItem(title: "Chapter \(index + 1)", path: path, fragment: nil, depth: 0)
                }
            }

            let coverCandidate: ManifestItem?
            if let propCover = opf.manifestItems.first(where: { $0.properties.contains("cover-image") }) {
                coverCandidate = propCover
            } else if let metaCoverID = opf.metaCoverID {
                coverCandidate = manifestByID[metaCoverID]
            } else {
                coverCandidate = nil
            }

            let resolvedCoverPath: String?
            if let candidate = coverCandidate,
               (candidate.mediaType == "image/jpeg" || candidate.mediaType == "image/png"),
               let coverEntry = extraction.entries[candidate.path] {
                guard coverEntry.byteCount <= limits.imageBytes else {
                    throw EPUBError.limitExceeded
                }
                resolvedCoverPath = candidate.path
            } else {
                resolvedCoverPath = nil
            }

            var servedResources: [EPUBResource] = []
            var servedPaths: Set<String> = []

            for spinePath in spinePaths {
                guard let sanitized = sanitizedByPath[spinePath] else {
                    throw EPUBError.invalidPackage
                }
                try writeSanitizedFile(sanitized.xhtmlData, at: spinePath, under: destination)
                let sha = EPUBResourceStore.digest(sanitized.xhtmlData)
                servedResources.append(
                    EPUBResource(
                        path: spinePath,
                        mediaType: "application/xhtml+xml",
                        sha256: sha,
                        byteCount: sanitized.xhtmlData.count
                    )
                )
                servedPaths.insert(spinePath)
            }

            var imagePaths = referencedBodyImages
            if let resolvedCoverPath {
                imagePaths.insert(resolvedCoverPath)
            }
            for imagePath in imagePaths.sorted() {
                guard let item = manifestByPath[imagePath],
                      (item.mediaType == "image/jpeg" || item.mediaType == "image/png"),
                      let imgEntry = extraction.entries[imagePath] else {
                    throw EPUBError.invalidPackage
                }
                guard imgEntry.byteCount <= limits.imageBytes else {
                    throw EPUBError.limitExceeded
                }
                servedResources.append(
                    EPUBResource(
                        path: imagePath,
                        mediaType: item.mediaType,
                        sha256: imgEntry.sha256,
                        byteCount: imgEntry.byteCount
                    )
                )
                servedPaths.insert(imagePath)
            }

            for extractedPath in extraction.entries.keys where !servedPaths.contains(extractedPath) {
                let url = fileURL(for: extractedPath, under: destination)
                try? FileManager.default.removeItem(at: url)
            }

            return EPUBPackage(
                sourceSHA256: extraction.sourceSHA256,
                parserVersion: EPUBFormat.parserVersion,
                title: title,
                spine: spinePaths,
                navigation: navigation,
                resources: servedResources,
                textNodes: textNodesByPath,
                coverPath: resolvedCoverPath
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private struct ManifestItem {
        let id: String
        let path: String
        let mediaType: String
        let properties: Set<String>
    }

    private struct ParsedOPF {
        let title: String
        let manifestItems: [ManifestItem]
        let spineIDRefs: [String]
        let spineTOCID: String?
        let metaCoverID: String?
    }

    private static func fileURL(for canonicalPath: String, under destination: URL) -> URL {
        var url = destination
        for component in canonicalPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private static func readExtractedFile(at canonicalPath: String, under destination: URL, expectedSize: Int) throws -> Data {
        let url = fileURL(for: canonicalPath, under: destination)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            throw EPUBError.unsafePath
        }
        guard values.isRegularFile == true, values.fileSize == expectedSize else {
            throw EPUBError.corruptResource
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: expectedSize + 1) ?? Data()
        guard data.count == expectedSize else {
            throw EPUBError.corruptResource
        }
        return data
    }

    private static func writeSanitizedFile(_ data: Data, at canonicalPath: String, under destination: URL) throws {
        let url = fileURL(for: canonicalPath, under: destination)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw EPUBError.unsafePath
        }
        guard values.isRegularFile == true else {
            throw EPUBError.corruptResource
        }
        try data.write(to: url, options: .atomic)
    }

    private static func parseContainer(_ rawData: Data, limits: EPUBLimits) throws -> String {
        let xmlData = try EPUBXMLSupport.prepareXMLData(rawData, limit: limits.xmlBytes)
        let delegate = ContainerXMLDelegate()
        try EPUBXMLSupport.parse(xmlData, delegate: delegate)
        guard delegate.sawContainer, delegate.sawRootfiles, let rawFullPath = delegate.selectedFullPath else {
            throw EPUBError.invalidPackage
        }
        let resolved: (path: String, fragment: String?)
        do {
            resolved = try EPUBResourcePath.resolve(rawFullPath, relativeTo: "")
        } catch let error as EPUBError {
            throw error
        } catch {
            throw EPUBError.invalidPackage
        }
        guard resolved.fragment == nil else {
            throw EPUBError.invalidPackage
        }
        return resolved.path
    }

    private static func parseOPF(_ rawData: Data, opfPath: String, limits: EPUBLimits) throws -> ParsedOPF {
        let xmlData = try EPUBXMLSupport.prepareXMLData(rawData, limit: limits.xmlBytes)
        let delegate = OPFPackageDelegate(opfPath: opfPath, limits: limits)
        try EPUBXMLSupport.parse(xmlData, delegate: delegate)
        guard delegate.sawPackage, delegate.sawMetadata, delegate.sawManifest, delegate.sawSpine else {
            throw EPUBError.invalidPackage
        }
        return ParsedOPF(
            title: delegate.title,
            manifestItems: delegate.manifestItems,
            spineIDRefs: delegate.spineIDRefs,
            spineTOCID: delegate.spineTOCID,
            metaCoverID: delegate.metaCoverID
        )
    }

    private final class ContainerXMLDelegate: EPUBXMLBaseDelegate {
        var sawContainer = false
        var sawRootfiles = false
        var selectedFullPath: String?

        override func handleStartElement(
            name: String,
            localName: String,
            prefix: String?,
            attributes: [String: String],
            parser: XMLParser
        ) throws {
            let lower = localName.lowercased()
            if lower == "container" {
                sawContainer = true
            } else if lower == "rootfiles" {
                guard sawContainer else { throw EPUBError.invalidPackage }
                sawRootfiles = true
            } else if lower == "rootfile" {
                guard sawRootfiles else { throw EPUBError.invalidPackage }
                guard let fullPath = attributes["full-path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !fullPath.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                if let mediaType = attributes["media-type"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !mediaType.isEmpty,
                   mediaType != "application/oebps-package+xml" {
                    throw EPUBError.invalidPackage
                }
                if selectedFullPath == nil {
                    selectedFullPath = fullPath
                }
            }
        }
    }

    private final class OPFPackageDelegate: EPUBXMLBaseDelegate {
        let opfPath: String
        let limits: EPUBLimits

        var sawPackage = false
        var sawMetadata = false
        var sawManifest = false
        var sawSpine = false

        var inMetadata = false
        var inManifest = false
        var inSpine = false
        var inTitle = false
        var currentTitle = ""
        var title = ""

        var activeMetaProperty: String?
        var currentMetaText = ""
        var metaCoverID: String?

        var manifestItems: [ManifestItem] = []
        var seenManifestIDs: Set<String> = []
        var seenManifestPaths: Set<String> = []

        var spineIDRefs: [String] = []
        var spineTOCID: String?

        init(opfPath: String, limits: EPUBLimits) {
            self.opfPath = opfPath
            self.limits = limits
        }

        override func handleStartElement(
            name: String,
            localName: String,
            prefix: String?,
            attributes: [String: String],
            parser: XMLParser
        ) throws {
            let lower = localName.lowercased()
            if lower == "package" {
                guard !sawPackage, ["2.0", "3.0"].contains(attributes["version"] ?? "") else { throw EPUBError.invalidPackage }
                sawPackage = true
                return
            }
            guard sawPackage else { throw EPUBError.invalidPackage }

            if lower == "metadata" {
                guard !sawMetadata else { throw EPUBError.invalidPackage }
                sawMetadata = true
                inMetadata = true
                return
            }
            if lower == "manifest" {
                guard !sawManifest else { throw EPUBError.invalidPackage }
                sawManifest = true
                inManifest = true
                return
            }
            if lower == "spine" {
                guard !sawSpine else { throw EPUBError.invalidPackage }
                sawSpine = true
                inSpine = true
                if let toc = attributes["toc"]?.trimmingCharacters(in: .whitespacesAndNewlines), !toc.isEmpty {
                    spineTOCID = toc
                }
                return
            }

            if inMetadata {
                if lower == "title" {
                    inTitle = true
                    currentTitle = ""
                } else if lower == "meta" {
                    let metaName = attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let metaContent = attributes["content"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if metaName == "fixed-layout", metaContent?.lowercased() == "true" {
                        throw EPUBError.unsupportedContent
                    }
                    if metaName == "rendition:layout", metaContent?.lowercased() == "pre-paginated" {
                        throw EPUBError.unsupportedContent
                    }
                    if metaName == "cover", let metaContent, !metaContent.isEmpty, metaCoverID == nil {
                        metaCoverID = metaContent
                    }
                    if let prop = attributes["property"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                        activeMetaProperty = prop
                        currentMetaText = ""
                    }
                }
                return
            }

            if inManifest, lower == "item" {
                guard let id = attributes["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let rawHref = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let mediaType = attributes["media-type"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !id.isEmpty, !rawHref.isEmpty, !mediaType.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                guard seenManifestIDs.insert(id).inserted else {
                    throw EPUBError.invalidPackage
                }
                let resolved = try EPUBResourcePath.resolve(rawHref, relativeTo: opfPath)
                guard resolved.fragment == nil else {
                    throw EPUBError.invalidPackage
                }
                guard seenManifestPaths.insert(resolved.path).inserted else {
                    throw EPUBError.invalidPackage
                }
                let propTokens = Set(
                    (attributes["properties"] ?? "")
                        .lowercased()
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                )
                manifestItems.append(
                    ManifestItem(
                        id: id,
                        path: resolved.path,
                        mediaType: mediaType,
                        properties: propTokens
                    )
                )
                return
            }

            if inSpine, lower == "itemref" {
                let propTokens = Set(
                    (attributes["properties"] ?? "")
                        .lowercased()
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                )
                if propTokens.contains("rendition:layout-pre-paginated") || propTokens.contains("layout-pre-paginated") {
                    throw EPUBError.unsupportedContent
                }
                guard let idref = attributes["idref"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !idref.isEmpty else {
                    throw EPUBError.invalidPackage
                }
                spineIDRefs.append(idref)
                guard spineIDRefs.count <= limits.spineItems else {
                    throw EPUBError.limitExceeded
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
            if lower == "metadata" {
                inMetadata = false
            } else if lower == "manifest" {
                inManifest = false
            } else if lower == "spine" {
                inSpine = false
            } else if inMetadata, lower == "title", inTitle {
                inTitle = false
                let trimmed = currentTitle
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if title.isEmpty, !trimmed.isEmpty {
                    title = trimmed
                }
                currentTitle = ""
            } else if inMetadata, lower == "meta", let prop = activeMetaProperty {
                let value = currentMetaText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                activeMetaProperty = nil
                currentMetaText = ""
                if (prop == "rendition:layout" || prop.hasSuffix(":layout")), value == "pre-paginated" {
                    throw EPUBError.unsupportedContent
                }
            }
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            if inTitle {
                currentTitle.append(string)
            } else if activeMetaProperty != nil {
                currentMetaText.append(string)
            }
        }
    }
}
