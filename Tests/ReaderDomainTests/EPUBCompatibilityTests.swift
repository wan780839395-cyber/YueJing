import Foundation
import ImageIO
import Testing
@testable import ReaderDomain

struct EPUBCompatibilityTests {
    private static let pagePath = "OPS/Text/page.xhtml"
    private static let jpegPath = "OPS/Images/page.jpg"
    private static let webpPath = "OEBPS/images/page.webp"
    private static let xhtml11 = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
    private static let ncxDTD = "<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\" \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">"

    // Independently generated solid 2x2 lossless WebP and two-frame 2x2 WebP (Pillow).
    private static let webpBase64 = "UklGRh4AAABXRUJQVlA4TBEAAAAvAUAAAAfQtI4UtP+BiOh/AAA="
    private static let animatedWebPBase64 = "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAABWUDhMDwAAAC8BQAAABxDR//4HIqL/AQA="
    // A real 6400x6400 solid lossless image: 40,960,000 pixels, only 1628 encoded bytes.
    // Run-length spelling of the base64 keeps this synthetic fixture small in source.
    private static let oversizedWebPBase64 =
        "UklGRlQGAABXRUJQVlA4TEgGAAAv/9g/BgfQtI4UtP/BEhIQ/J/tgBgRE4BbEwFJ0v/9gRH9T6BA/P1HEZHxn//++++///777z///ffff//9999//vPff//9999///3333///"
        + String(repeating: "ffff//9999///3333///", count: 100)
        + "ffff//577///vvvv//+899///3333///ef/4AA="

    @Test func epubCompatibilityStandardDoctypesPreserveAcceptedTextBytesAndNodes() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let plain = Self.xhtml("<p id=\"heading\">A😀e\u{301} &amp; &lt;text&gt;</p>")
        let plainData = Data(plain.utf8)
        #expect(try EPUBXMLSupport.prepareXMLData(plainData, limit: EPUBLimits().xhtmlBytes) == plainData)
        let baseline = try Self.sanitize(plainData, at: root)
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><meta http-equiv="Content-Security-Policy" content="\(EPUBContentPolicy.contentSecurityPolicy)"/><title>Synthetic</title></head><body><p id="heading"><span id="yj-t0">A😀e\u{301} &amp; &lt;text&gt;</span></p></body></html>
        """
        #expect(baseline.xhtmlData == Data(expected.utf8))
        #expect(baseline.textNodes == ["A😀e\u{301} & <text>"])
        #expect(baseline.fragmentIDs == ["heading"])
        #expect(EPUBFormat.parserVersion == "epub-dom-v1")
        #expect(EPUBFormat.positionUnit == "epub-text-node-utf16-v1")

        let declarations = [
            "<!DOCTYPE html>", Self.xhtml11,
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">",
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">",
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Frameset//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd\">"
        ]
        for declaration in declarations {
            for input in Self.xmlEncodings(declaration + "\n" + plain) {
                let prepared = try EPUBXMLSupport.prepareXMLData(input, limit: EPUBLimits().xhtmlBytes)
                #expect(!String(decoding: prepared, as: UTF8.self).contains("<!DOCTYPE"))
                #expect(try Self.sanitize(input, at: root) == baseline)
            }
        }
        let prolog = "<?xml version=\"1.0\"?>\n<!-- synthetic prolog -->\n" + Self.xhtml11 + "\n"
        #expect(try Self.sanitize(Data((prolog + plain).utf8), at: root) == baseline)
        let ncx = Self.ncxDocument
        let expectedNavigation = [EPUBNavigationItem(title: "Image page", path: "OEBPS/page.xhtml", fragment: "heading")]
        for input in Self.xmlEncodings(Self.ncxDTD + "\n" + ncx) {
            let prepared = try EPUBXMLSupport.prepareXMLData(input, limit: EPUBLimits().xmlBytes)
            #expect(!String(decoding: prepared, as: UTF8.self).contains("<!DOCTYPE"))
            #expect(try EPUBNavigationParser.parseNCX(data: input, ncxPath: "OEBPS/toc.ncx",
                spineSet: ["OEBPS/page.xhtml"], fragmentIDsByPath: ["OEBPS/page.xhtml": ["heading"]]) == expectedNavigation)
        }
        #expect(try EPUBXMLSupport.prepareXMLData(Data(ncx.utf8), limit: EPUBLimits().xmlBytes) == Data(ncx.utf8))
    }

    @Test func epubCompatibilityRejectsEntitiesUnknownDuplicateAndMisplacedDoctypes() throws {
        let plain = Self.xhtml("<p>Safe text</p>")
        let forbidden = [
            "<!DOCTYPE html [<!ENTITY xxe SYSTEM \"file:///synthetic-never-read\">]>" + Self.xhtml("<p>&xxe;</p>"),
            "<!DOCTYPE html [<!ENTITY xxe SYSTEM \"https://example.invalid/entity\">]>" + plain,
            "<!DOCTYPE html [<!ENTITY word \"expanded\">]>" + plain,
            "<!DOCTYPE html []>" + plain,
            String(Self.xhtml11.dropLast()) + " [<!ENTITY word \"expanded\">]>" + plain,
            "<!DOCTYPE html [<!ENTITY % remote SYSTEM \"https://example.invalid/dtd\">%remote;]>" + plain,
            "<!ENTITY word \"expanded\">" + plain,
            "<!DOCTYPE html SYSTEM \"https://example.invalid/unknown.dtd\">" + plain,
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"https://example.invalid/xhtml11.dtd\">" + plain,
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">" + plain,
            "<!DOCTYPE html PUBLIC \"Unknown public identifier\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">" + plain,
            "<!DOCTYPE html><!DOCTYPE html>" + plain,
            Self.xhtml11 + Self.xhtml11 + plain,
            Self.ncxDTD + plain,
            "<!DOCTYPE html>" + Self.ncxDocument,
            plain + "<!DOCTYPE html>",
            Self.xhtml("<!DOCTYPE html><p>Nested declaration</p>"),
            "<!-- not a declaration -->" + plain + Self.xhtml11
        ]
        for xml in forbidden {
            for data in Self.xmlEncodings(xml) {
                #expect(throws: EPUBError.invalidPackage) {
                    _ = try EPUBXMLSupport.prepareXMLData(data, limit: EPUBLimits().xhtmlBytes)
                }
            }
        }
    }

    @Test func epubCompatibilityStaticSVGBecomesLocalJPEGAndPreservesIDs() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try EPUBTestSupport.jpegData(width: 2, height: 2)
        try Self.writeResource(jpeg, path: Self.jpegPath, under: root)
        let wrappers = [
            Self.xhtml("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" id=\"plate\" viewBox=\"0 0 2 2\" width=\"2\" height=\"2\"><image id=\"picture\" width=\"2\" height=\"2\" xlink:href=\"../Images/page.jpg\"/></svg><p>Caption</p>"),
            Self.xhtml("<svg:svg id=\"plate\" viewBox=\"0 0 2 2\"><svg:image id=\"picture\" href=\"../Images/page.jpg\"/></svg:svg><p>Caption</p>", attributes: " xmlns:svg=\"http://www.w3.org/2000/svg\"")
        ]
        for xml in wrappers {
            let clean = try Self.sanitize(Data(xml.utf8), at: root, images: [Self.jpegPath: "image/jpeg"])
            let output = String(decoding: clean.xhtmlData, as: UTF8.self)
            #expect(clean.textNodes == ["Caption"])
            #expect(clean.referencedImages == [Self.jpegPath])
            #expect(clean.fragmentIDs == ["plate", "picture"])
            #expect(output.contains("<div ") && output.contains("id=\"plate\""))
            #expect(output.contains("<img ") && output.contains("id=\"picture\""))
            #expect(output.contains("src=\"../Images/page.jpg\""))
            #expect(!output.contains("<svg") && !output.contains("<image"))
            #expect(!output.contains("xlink") && !output.contains("viewBox") && !output.contains("2000/svg"))
            #expect(try Data(contentsOf: root.appendingPathComponent(Self.jpegPath)) == jpeg)
        }
    }

    @Test func epubCompatibilityRejectsComplexActiveAndEscapingSVG() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeResource(try EPUBTestSupport.jpegData(width: 2, height: 2), path: Self.jpegPath, under: root)
        let image = "<image href=\"../Images/page.jpg\"/>"
        let badBodies = [
            Self.svg("<rect width=\"2\" height=\"2\"/>"),
            Self.svg(image + "<rect/>"), Self.svg(image + image), Self.svg("<g>" + image + "</g>"),
            Self.svg("<script>bad()</script>" + image), Self.svg("<foreignObject/>" + image),
            Self.svg("<image href=\"../Images/page.jpg\"><animate attributeName=\"x\"/></image>"),
            Self.svg("<image href=\"../Images/page.jpg\">unexpected text</image>"),
            Self.svg(image + "unexpected text"), Self.svg(""),
            Self.svg(image, attributes: " onload=\"bad()\""),
            Self.svg("<image href=\"../Images/page.jpg\" onerror=\"bad()\"/>"),
            Self.svg(image, attributes: " style=\"background:url(https://example.invalid/a)\""),
            Self.svg(image, attributes: " unknown=\"not-whitelisted\""),
            Self.svg("<image href=\"../Images/page.jpg\" filter=\"url(#effect)\"/>"),
            Self.svg("<image href=\"https://example.invalid/p.jpg\"/>"),
            Self.svg("<image href=\"//example.invalid/p.jpg\"/>"),
            Self.svg("<image href=\"file:///synthetic-never-read.jpg\"/>"),
            Self.svg("<image href=\"data:image/jpeg;base64,/9j/\"/>"),
            Self.svg("<image href=\"../../../outside.jpg\"/>"),
            Self.svg("<image href=\"%2e%2e/%2e%2e/%2e%2e/outside.jpg\"/>"),
            Self.svg("<image href=\"../Images/missing.jpg\"/>"),
            "<svg:svg><svg:image href=\"../Images/page.jpg\"/></svg:svg>",
            "<svg xmlns=\"https://example.invalid/fake-svg\">" + image + "</svg>",
            Self.svg("<image xmlns:xlink=\"https://example.invalid/fake-xlink\" xlink:href=\"../Images/page.jpg\"/>")
        ]
        for body in badBodies {
            // Existing text prevents an empty-body rejection from hiding SVG acceptance.
            #expect(throws: (any Error).self) {
                _ = try Self.sanitize(Data(Self.xhtml(body + "<p>Still text</p>").utf8), at: root,
                    images: [Self.jpegPath: "image/jpeg"])
            }
        }
    }

    @Test func epubCompatibilityImageOnlyPagesHaveStableAnchorButBlankPagesFail() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeResource(try EPUBTestSupport.jpegData(width: 2, height: 2), path: Self.jpegPath, under: root)
        try Self.writeResource(try EPUBTestSupport.pngData(width: 2, height: 2), path: "OPS/Images/page.png", under: root)
        try Self.writeResource(try Self.webpData(), path: "OPS/Images/page.webp", under: root)
        let images = [Self.jpegPath: "image/jpeg", "OPS/Images/page.png": "image/png", "OPS/Images/page.webp": "image/webp"]
        for body in [
            " \n<div id=\"heading\"><img src=\"../Images/page.jpg\" alt=\"Synthetic illustration\"/></div> \n",
            "<img id=\"heading\" src=\"../Images/page.png\"/>",
            "<img id=\"heading\" src=\"../Images/page.webp\"/>",
            Self.svg("<image href=\"../Images/page.jpg\"/>", attributes: " id=\"heading\"")
        ] {
            let clean = try Self.sanitize(Data(Self.xhtml(body).utf8), at: root, images: images)
            #expect(clean.textNodes == ["图片页"])
            #expect(clean.fragmentIDs.contains("heading"))
            #expect(clean.referencedImages.count == 1)
            let output = String(decoding: clean.xhtmlData, as: UTF8.self)
            #expect(output.contains("<span id=\"yj-t0\">图片页</span>"))
            #expect(!output.contains("yj-t1"))
            #expect(try Self.sanitize(Data(Self.xhtml(body).utf8), at: root, images: images) == clean)
        }
        for body in ["", " \n\t ", "<div id=\"heading\"> \n </div>"] {
            #expect(throws: EPUBError.invalidPackage) {
                _ = try Self.sanitize(Data(Self.xhtml(body).utf8), at: root, images: images)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try Self.sanitize(Data(Self.xhtml("<img src=\"../Images/missing.jpg\"/>").utf8), at: root, images: images)
        }
        try Self.writeResource(Data("not a JPEG".utf8), path: Self.jpegPath, under: root)
        #expect(throws: EPUBError.corruptResource) {
            _ = try Self.sanitize(Data(Self.xhtml("<img src=\"../Images/page.jpg\"/>").utf8), at: root, images: images)
        }
    }

    @Test func epubCompatibilityWebPRequiresRealBoundedSingleFrameDecode() throws {
        let webp = try Self.webpData()
        #expect(webp.prefix(4) == Data("RIFF".utf8))
        #expect(webp.subdata(in: 8..<12) == Data("WEBP".utf8))
        try EPUBContentPolicy.verifyImageData(webp, mediaType: "image/webp")
        let source = try #require(CGImageSourceCreateWithData(webp as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        #expect(image.width == 2 && image.height == 2)
        #expect(image.dataProvider?.data != nil)

        let animated = try #require(Data(base64Encoded: Self.animatedWebPBase64))
        let oversized = try #require(Data(base64Encoded: Self.oversizedWebPBase64))
        #expect(oversized.count == 1628)
        let largeSource = try #require(CGImageSourceCreateWithData(oversized as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(largeSource, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 6400)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 6400)
        var wrongRIFF = webp; wrongRIFF[0] = 0
        var wrongWEBP = webp; wrongWEBP[8] = 0
        let fakeHeader = Data("RIFF".utf8) + Data([4, 0, 0, 0]) + Data("WEBP".utf8)
        for bad in [Data(), wrongRIFF, wrongWEBP, fakeHeader, Data(webp.prefix(24)), animated, oversized,
                    try Self.webpWithDeclaredCanvas(width: 16385, height: 1)] {
            #expect(throws: (any Error).self) {
                try EPUBContentPolicy.verifyImageData(bad, mediaType: "image/webp")
            }
        }
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBContentPolicy.verifyImageData(Self.webpWithDeclaredCanvas(width: 16385, height: 1), mediaType: "image/webp")
        }
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBContentPolicy.verifyImageData(oversized, mediaType: "image/webp")
        }
        let png = try EPUBTestSupport.pngData(width: 2, height: 2)
        let jpeg = try EPUBTestSupport.jpegData(width: 2, height: 2)
        try EPUBContentPolicy.verifyImageData(png, mediaType: "image/png")
        try EPUBContentPolicy.verifyImageData(jpeg, mediaType: "image/jpeg")
        for nonWebP in [png, jpeg] {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBContentPolicy.verifyImageData(nonWebP, mediaType: "image/webp")
            }
        }
        for mediaType in ["image/png", "image/jpeg"] {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBContentPolicy.verifyImageData(webp, mediaType: mediaType)
            }
        }
    }

    @Test func epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen() async throws {
        let fixture = try EPUBLibraryFixture(); defer { fixture.remove() }
        let archive = fixture.root.appendingPathComponent("synthetic-compatibility.epub")
        try Self.writeCompatibilityEPUB2(at: archive)
        let original = try Data(contentsOf: archive)
        let receipt = try await fixture.install(archive)
        #expect(receipt.book.format == .epub && !receipt.duplicate)
        let reader = try await fixture.service.openEPUB(id: receipt.book.id)
        let package = reader.publication.package
        #expect(package.spine == ["OEBPS/page.xhtml", "OEBPS/text.xhtml"])
        #expect(try package.nodes(at: "OEBPS/page.xhtml") == ["图片页"])
        #expect(try package.nodes(at: "OEBPS/text.xhtml") == ["Unchanged synthetic text"])
        #expect(package.navigation == [EPUBNavigationItem(title: "Image page", path: "OEBPS/page.xhtml", fragment: "heading")])
        #expect(package.parserVersion == "epub-dom-v1")
        #expect(try EPUBResourceStore.data(path: Self.webpPath, publication: reader.publication) == Self.webpData())
        let page = try EPUBResourceStore.data(path: "OEBPS/page.xhtml", publication: reader.publication)
        #expect(String(decoding: page, as: UTF8.self).contains("id=\"yj-t0\">图片页</span>"))
        #expect(!String(decoding: page, as: UTF8.self).contains("<svg"))
        let position = EPUBReadingPosition(bookID: reader.book.id, versionID: reader.book.versionID,
            path: "OEBPS/page.xhtml", node: 0, utf16Offset: 1)
        try position.validate(in: package)
        #expect(position.unit == "epub-text-node-utf16-v1")
        let token = try await reader.beginNavigation(path: position.path)
        #expect(try await reader.markReady(token))
        #expect(try await reader.save(position, sequence: 1, token: token))
        try await reader.close(position: position, sequence: 2, token: token, preferences: reader.preferences)
        let fresh = LibraryService(store: try LibraryStore(root: fixture.managed))
        let reopened = try await fresh.openEPUB(id: receipt.book.id)
        #expect(reopened.reading.position == position)
        #expect(reopened.publication.package == package)
        #expect(try EPUBResourceStore.data(path: Self.webpPath, publication: reopened.publication) == Self.webpData())
        try await reopened.close(position: nil, sequence: 1, token: nil, preferences: reopened.preferences)
        #expect(try Data(contentsOf: archive) == original)
        #expect(try Data(contentsOf: await fixture.store.epubFileURL(bookID: receipt.book.id)) == original)
    }

    @Test func epubCompatibilityWebPResourcesStillEnforceSizeAndDigestIntegrity() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("synthetic-integrity.epub")
        try Self.writeCompatibilityEPUB2(at: archive)
        let destination = root.appendingPathComponent("resources", isDirectory: true)
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
        let publication = EPUBPublication(package: package, resourceRoot: destination)
        let resource = try #require(package.resource(at: Self.webpPath))
        let expected = try Self.webpData()
        #expect(resource.mediaType == "image/webp")
        #expect(resource.byteCount == expected.count)
        #expect(resource.sha256 == EPUBResourceStore.digest(expected))
        #expect(try EPUBResourceStore.data(path: Self.webpPath, publication: publication) == expected)
        let url = destination.appendingPathComponent(Self.webpPath)
        var changed = expected; changed[changed.count - 1] ^= 0x01
        for damaged in [changed, Data(expected.dropLast()), expected + Data([0])] {
            try damaged.write(to: url)
            #expect(throws: EPUBError.corruptResource) {
                _ = try EPUBResourceStore.data(path: Self.webpPath, publication: publication)
            }
            try expected.write(to: url)
            #expect(try EPUBResourceStore.data(path: Self.webpPath, publication: publication) == expected)
        }
        let damagedArchive = root.appendingPathComponent("synthetic-invalid-webp.epub")
        try Self.writeCompatibilityEPUB2(at: damagedArchive, image: Data(expected.prefix(24)))
        let rejectedDestination = root.appendingPathComponent("rejected", isDirectory: true)
        #expect(throws: (any Error).self) {
            _ = try EPUBPackageParser.parse(archiveURL: damagedArchive, destination: rejectedDestination)
        }
        #expect(!FileManager.default.fileExists(atPath: rejectedDestination.path))
        // Optional cover failures fall back, whereas the same invalid body image above is fatal.
        let animated = try #require(Data(base64Encoded: Self.animatedWebPBase64))
        for (index, cover) in [expected, Data(expected.prefix(24)), animated].enumerated() {
            let coverArchive = root.appendingPathComponent("optional-cover-\(index).epub")
            let coverDestination = root.appendingPathComponent("optional-cover-\(index)", isDirectory: true)
            try EPUBTestSupport.writeEPUB2(at: coverArchive, title: "Synthetic optional cover",
                chapters: [EPUBSyntheticChapter(id: "text", path: "text.xhtml", title: "Text")],
                coverData: cover, coverHref: "images/page.webp", coverMediaType: "image/webp")
            let parsed = try EPUBPackageParser.parse(archiveURL: coverArchive, destination: coverDestination)
            if index == 0 {
                #expect(parsed.coverPath == Self.webpPath)
                #expect(parsed.resource(at: Self.webpPath) != nil)
            } else {
                #expect(parsed.coverPath == nil)
                #expect(parsed.resource(at: Self.webpPath) == nil)
                #expect(!FileManager.default.fileExists(atPath: coverDestination.appendingPathComponent(Self.webpPath).path))
            }
        }
    }

    private static func xhtml(_ body: String, attributes: String = "") -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"\(attributes)><head><title>Synthetic</title></head><body>\(body)</body></html>"
    }

    private static func svg(_ children: String, attributes: String = "") -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\"\(attributes)>\(children)</svg>"
    }

    private static func xmlEncodings(_ xml: String) -> [Data] {
        [Data(xml.utf8), Data([0xEF, 0xBB, 0xBF]) + Data(xml.utf8),
         EPUBTestSupport.encodeUTF16(xml, bigEndian: false),
         EPUBTestSupport.encodeUTF16(xml, bigEndian: true)]
    }

    private static func sanitize(_ data: Data, at root: URL, images: [String: String] = [:]) throws -> EPUBSanitizedDocument {
        var manifest = images
        manifest[pagePath] = "application/xhtml+xml"
        return try EPUBContentPolicy.sanitizeXHTML(data: data, path: pagePath,
            manifestByPath: manifest, spineSet: [pagePath], destination: root)
    }

    private static func writeResource(_ data: Data, path: String, under root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func webpData() throws -> Data {
        try #require(Data(base64Encoded: webpBase64))
    }

    private static func webpWithDeclaredCanvas(width: Int, height: Int) throws -> Data {
        // Forged extended header exercises the per-dimension guard without allocating a giant raster.
        var payload = Data("WEBPVP8X".utf8)
        payload.append(contentsOf: [10, 0, 0, 0, 0, 0, 0, 0])
        for value in [width - 1, height - 1] {
            payload.append(contentsOf: (0..<3).map { UInt8((value >> ($0 * 8)) & 0xFF) })
        }
        payload.append(try webpData().dropFirst(12))
        var result = Data("RIFF".utf8)
        result.append(contentsOf: (0..<4).map { UInt8((payload.count >> ($0 * 8)) & 0xFF) })
        result.append(payload)
        return result
    }

    private static let ncxDocument = "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>Synthetic compatibility</text></docTitle><navMap><navPoint id=\"p1\" playOrder=\"1\"><navLabel><text>Image page</text></navLabel><content src=\"page.xhtml#heading\"/></navPoint></navMap></ncx>"

    private static func writeCompatibilityEPUB2(at url: URL, image: Data? = nil) throws {
        let page = xhtml11 + "\n" + xhtml(svg("<image href=\"images/page.webp\"/>", attributes: " id=\"heading\""))
        let text = "<!DOCTYPE html>\n" + xhtml("<p id=\"text-heading\">Unchanged synthetic text</p>")
        try EPUBTestSupport.writeEPUB2(at: url, title: "Synthetic compatibility EPUB2",
            chapters: [
                EPUBSyntheticChapter(id: "page", path: "page.xhtml", title: "Image page", bodyXHTML: page),
                EPUBSyntheticChapter(id: "text", path: "text.xhtml", title: "Text page", headingID: "text-heading", bodyXHTML: text)
            ], coverData: try image ?? webpData(), coverHref: "images/page.webp", coverMediaType: "image/webp",
            ncxXML: ncxDTD + "\n" + ncxDocument)
    }
}
