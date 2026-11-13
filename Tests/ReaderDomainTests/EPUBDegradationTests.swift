import Foundation
import Testing
import ZIPFoundation
@testable import ReaderDomain

final class EPUBPreparationSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [EPUBPreparationSample] = []
    func record(_ sample: EPUBPreparationSample) {
        lock.lock(); defer { lock.unlock() }
        if samples.count < 128 { samples.append(sample) }
    }
    var values: [EPUBPreparationSample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

struct EPUBDegradationTests {
    private func document(_ body: String, head: String = "") -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>\(head)</head><body>\(body)</body></html>"
    }

    @Test func inertLinksHintsAndLegacyTagsPreserveNodesWithoutCapabilities() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let text = document("<center id=\"heading\"><font face=\"Old\">One</font><strike>Two</strike></center><noscript><p>Fallback</p></noscript>" +
            ["https://example.invalid/x", "http://example.invalid", "mailto:a@example.invalid", "tel:123", "//example.invalid", "missing.xhtml"].map {
                "<a href=\"\($0)\">Link</a>"
            }.joined(), head: "<link rel=\"preload\" as=\"font\" href=\"https://example.invalid/f.ttf\"/><link rel=\"prefetch\" href=\"remote.xhtml\"/>")
        let clean = try EPUBContentPolicy.sanitizeXHTML(data: Data(text.utf8), path: "OPS/c.xhtml", manifestByPath: [:], spineSet: ["OPS/c.xhtml"], destination: root)
        #expect(clean.textNodes == ["One", "Two", "Fallback"] + Array(repeating: "Link", count: 6))
        #expect(clean.fragmentIDs.contains("heading"))
        let output = String(decoding: clean.xhtmlData, as: UTF8.self)
        for absent in [" href=", "<link", "<font", "<center", "<noscript", "example.invalid", " face="] { #expect(!output.contains(absent)) }
        #expect(output.contains("<s>"))
        #expect(clean.referencedLinks.isEmpty && clean.referencedFonts.isEmpty)
        for unsafe in ["javascript:alert(1)", "data:text/html,x", "file:///a", "yjepub://other/x"] {
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBContentPolicy.sanitizeXHTML(data: Data(document("<a href=\"\(unsafe)\">T</a>").utf8), path: "OPS/c.xhtml", manifestByPath: [:], spineSet: ["OPS/c.xhtml"], destination: root)
            }
        }
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBContentPolicy.sanitizeXHTML(data: Data(document("<noscript><script>bad()</script></noscript>").utf8), path: "OPS/c.xhtml", manifestByPath: [:], spineSet: ["OPS/c.xhtml"], destination: root)
        }
    }

    @Test func optionalStylesRollbackEarlierRulesAndNeverHideIntegrityFailure() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid font".utf8).write(to: root.appendingPathComponent("bad.ttf"))
        let eofComment = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility("p { color: #123456; } /* unterminated",
            sourcePath: "s.css", documentPath: "c.xhtml", manifestByPath: [:], destination: root)
        #expect(eofComment.css.contains("#123456") && !eofComment.css.contains("unterminated"))
        #expect(eofComment.referencedFonts.isEmpty && !eofComment.styleCompatibility.usesReaderLayout)
        for bad in ["p { content: \"unclosed", "@font-face {font-family: Bad; src: url(bad.ttf);}"] {
            let xhtml = document("<p style=\"color: #654321\">Kept😀</p>", head: "<style>p {color: #112233}</style><style>\(bad)</style>")
            let clean = try EPUBContentPolicy.sanitizeXHTML(data: Data(xhtml.utf8), path: "c.xhtml", manifestByPath: ["bad.ttf": "font/ttf"], spineSet: ["c.xhtml"], destination: root)
            #expect(clean.textNodes == ["Kept😀"])
            #expect(clean.referencedFonts.isEmpty && clean.styleCompatibility.usesReaderLayout)
            #expect(!String(decoding: clean.xhtmlData, as: UTF8.self).contains("data-yj-author-style="))
        }
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBAuthorStyles.verifyExtractedFont(at: "bad.ttf", under: root, declaredMediaType: "font/ttf", expectedSize: 999, optionalStyle: true)
        }
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBAuthorStyles.verifyExtractedFont(at: "../bad.ttf", under: root, declaredMediaType: "font/ttf", optionalStyle: true)
        }
    }

    @Test func recognizedFontObfuscationOmitsBytesButUnknownProtectionStillFails() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        func metadata(_ algorithm: String, _ path: String) -> String {
            "<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><EncryptedData xmlns=\"http://www.w3.org/2001/04/xmlenc#\"><EncryptionMethod Algorithm=\"\(algorithm)\"/><CipherData><CipherReference URI=\"\(path)\"/></CipherData></EncryptedData></encryption>"
        }
        for algorithm in ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"] {
            let archive = root.appendingPathComponent(UUID().uuidString + ".epub")
            try EPUBTestSupport.writeEPUB3(at: archive, chapters: [.init(id: "c", path: "c.xhtml", title: "C", bodyXHTML: document("<p id=\"heading\">Kept</p>", head: "<style>@font-face {font-family: Hidden; src: url(f.ttf);} p {font-family: Hidden,serif;}</style>"))], manifestExtra: "<item id=\"f\" href=\"f.ttf\" media-type=\"font/ttf\"/>", extraEntries: [("OPS/f.ttf", Data("obfuscated synthetic bytes".utf8)), ("META-INF/encryption.xml", Data(metadata(algorithm, "OPS/f.ttf").utf8))])
            let dest = root.appendingPathComponent(UUID().uuidString)
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: dest)
            #expect(package.resources.allSatisfy { !$0.mediaType.hasPrefix("font/") })
            #expect(package.textNodes["OPS/c.xhtml"] == ["Kept"])
            #expect(package.styleCompatibility?.issues.contains(.obfuscatedFontOmitted) == true)
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("OPS/f.ttf").path))
        }
        for pair in [("unknown", "OPS/f.ttf"), ("http://www.idpf.org/2008/embedding", "OPS/c.xhtml")] {
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBFontObfuscation.omittedFonts(data: Data(metadata(pair.0, pair.1).utf8), manifest: ["OPS/f.ttf": "font/ttf", "OPS/c.xhtml": "application/xhtml+xml"], entries: ["OPS/f.ttf", "OPS/c.xhtml"], limit: 2048)
            }
        }
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBFontObfuscation.omittedFonts(data: Data(metadata("http://www.idpf.org/2008/embedding", "../escape.ttf").utf8), manifest: [:], entries: [], limit: 2048)
        }
    }

    @Test func missingManifestRasterRequiresActualBoundedDecodeAndPreservesSource() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        for image in [try EPUBTestSupport.pngData(width: 2, height: 2), try EPUBTestSupport.jpegData(width: 2, height: 2)] {
            let archive = root.appendingPathComponent(UUID().uuidString + ".epub")
            try EPUBTestSupport.writeEPUB3(at: archive, chapters: [.init(id: "c", path: "c.xhtml", title: "C", bodyXHTML: document("<p id=\"heading\">Kept</p><img src=\"picture.bin\"/>"))], extraEntries: [("OPS/picture.bin", image)])
            let before = try EPUBResourceStore.sourceDigest(archive)
            let dest = root.appendingPathComponent(UUID().uuidString)
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: dest)
            #expect(package.sourceSHA256 == before)
            #expect(try EPUBResourceStore.sourceDigest(archive) == before)
            #expect(package.resource(at: "OPS/picture.bin")?.sha256 == EPUBResourceStore.digest(image))
            #expect(package.styleCompatibility?.issues.contains(.manifestImageRecovered) == true)
            try EPUBPublicationCache.verifyResources(.init(package: package, resourceRoot: dest))
        }
        let archive = root.appendingPathComponent("bad-image.epub")
        try EPUBTestSupport.writeEPUB3(at: archive, chapters: [.init(id: "c", path: "c.xhtml", title: "C", bodyXHTML: document("<p id=\"heading\">Kept</p><img src=\"bad.png\"/>"))], extraEntries: [("OPS/bad.png", Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]))])
        #expect(throws: EPUBError.corruptResource) { _ = try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("bad")) }
    }

    @Test func svgMarkerAndPackagingWhitespaceUseContentValidationNotMetadataRejection() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("static.epub")
        let image = try EPUBTestSupport.jpegData(width: 2, height: 2)
        let opf = "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title> </dc:title></metadata><manifest><item id=\"c\" href=\"c.xhtml\" media-type=\"application/xhtml+xml\" properties=\"svg\"/><item id=\"n\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"old\" href=\"bad.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"i\" href=\"i.jpg\" media-type=\"image/jpeg\"/></manifest><spine toc=\"old\"><itemref idref=\"c\"/></spine></package>"
        try EPUBTestSupport.writeZIP(at: archive, entries: [
            ("mimetype", Data("application/epub+zip\r\n".utf8), .deflate),
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8), .none),
            ("OPS/book.opf", Data(opf.utf8), .none),
            ("OPS/c.xhtml", Data(document("<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"i.jpg\"/></svg>").utf8), .none),
            ("OPS/nav.xhtml", Data(document("<nav xmlns:epub=\"http://www.idpf.org/2007/ops\" epub:type=\"toc\"><ol><li><a href=\"c.xhtml\">Image</a></li></ol></nav>").utf8), .none),
            ("OPS/bad.ncx", Data("obsolete malformed backup".utf8), .none),
            ("OPS/i.jpg", image, .none)
        ])
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("ready"))
        #expect(package.title == "未命名书籍")
        #expect(package.textNodes["OPS/c.xhtml"] == ["图片页"])
        #expect(package.navigation.first?.title == "Image")
        #expect(package.styleCompatibility?.issues.contains(.navigationUnavailable) != true)
    }

    @Test func preparationStagesAndFailureCodesAreNumericAndIdentityFree() throws {
        let samples = EPUBPreparationSamples()
        let trace = EPUBPreparationTrace(observer: samples.record)
        trace.totalChapters = 1633; trace.completedChapters = 64
        trace.emit(.chapters)
        trace.emit(.migration, failure: EPUBError.corruptResource)
        #expect(samples.values.first?.completedChapters == 64)
        #expect(samples.values.last?.failureCode == "migration_inconsistent")
        #expect(samples.values.allSatisfy { $0.elapsedMilliseconds >= 0 && $0.processPeakRSSBytes >= 0 })
        let failure = ImportSafeFailure(EPUBError.limitExceeded)
        #expect(failure.domain == .epub && failure.kind == .budget)
        #expect(failure.reasonCode == "processing_budget_exceeded")
        var presentation = LibraryImportPresentation()
        let id = UUID(); presentation.begin(id)
        presentation.receive(.epubChapters, for: id)
        #expect(presentation.title == "正在处理章节与样式…")
        presentation.receive(.epubReady, for: UUID())
        #expect(presentation.phase == .epubChapters)
    }
}
