import Foundation
import ImageIO
import Testing
import ZIPFoundation
@testable import ReaderDomain

struct EPUBPackageTests {
    @Test func epubPackageParsesEPUB3AndEPUB2ContainersInExactSpineOrder() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try EPUBTestSupport.pngData()
        let jpg = try EPUBTestSupport.jpegData()

        let chapters = [
            EPUBSyntheticChapter(
                id: "item-b",
                path: "Text/partB.xhtml",
                title: "Part B",
                headingID: "hb",
                bodyXHTML: """
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Part B</title><style>body { color: #111; }</style><link rel="stylesheet" href="../Styles/ignored.css"/></head><body><h1 id="hb">Part B &amp; &lt;1&gt;</h1><p>B😀e\u{301} text</p><p><img src="../Images/fig.png" alt="Figure"/> and <a href="partA.xhtml#ha">jump</a></p></body></html>
                """
            ),
            EPUBSyntheticChapter(
                id: "item-a",
                path: "Text/partA.xhtml",
                title: "Part A",
                headingID: "ha",
                bodyXHTML: """
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Part A</title></head><body><h1 id="ha">Part A</h1><p>Second spine chapter.</p></body></html>
                """
            ),
            EPUBSyntheticChapter(
                id: "item-c",
                path: "Text/partC.xhtml",
                title: "Part C",
                headingID: "hc",
                bodyXHTML: """
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Part C</title></head><body><h1 id="hc">Part C</h1><p>Third spine chapter.</p></body></html>
                """
            )
        ]

        let epub3URL = root.appendingPathComponent("book3.epub")
        try EPUBTestSupport.writeEPUB3(
            at: epub3URL,
            title: "EPUB3 顺序与净化回归",
            chapters: chapters,
            spineOrder: ["item-b", "item-a", "item-c"],
            coverData: png,
            coverHref: "Images/cover.png",
            coverMediaType: "image/png",
            manifestExtra: "<item id=\"fig\" href=\"Images/fig.png\" media-type=\"image/png\"/><item id=\"css\" href=\"Styles/ignored.css\" media-type=\"text/css\"/>",
            extraEntries: [
                ("OPS/Images/fig.png", png),
                ("OPS/Styles/ignored.css", Data("body { margin: 0; }".utf8))
            ]
        )

        let dest3A = root.appendingPathComponent("dest3A", isDirectory: true)
        let dest3B = root.appendingPathComponent("dest3B", isDirectory: true)
        let pkg3A = try EPUBPackageParser.parse(archiveURL: epub3URL, destination: dest3A)
        let pkg3B = try EPUBPackageParser.parse(archiveURL: epub3URL, destination: dest3B)

        #expect(pkg3A == pkg3B)
        #expect(pkg3A.title == "EPUB3 顺序与净化回归")
        #expect(pkg3A.spine == ["OPS/Text/partB.xhtml", "OPS/Text/partA.xhtml", "OPS/Text/partC.xhtml"])
        #expect(pkg3A.coverPath == "OPS/Images/cover.png")
        #expect(pkg3A.textNodes["OPS/Text/partB.xhtml"] == ["Part B & <1>", "B😀e\u{301} text", " and ", "jump"])
        #expect(pkg3A.resources.map(\.path) == [
            "OPS/Text/partB.xhtml",
            "OPS/Text/partA.xhtml",
            "OPS/Text/partC.xhtml",
            "OPS/Images/cover.png",
            "OPS/Images/fig.png"
        ])
        #expect(!FileManager.default.fileExists(atPath: dest3A.appendingPathComponent("OPS/Styles/ignored.css").path))
        #expect(!FileManager.default.fileExists(atPath: dest3A.appendingPathComponent("OPS/book.opf").path))

        let sanitizedB = try Data(contentsOf: dest3A.appendingPathComponent("OPS/Text/partB.xhtml"))
        let sanitizedBText = String(decoding: sanitizedB, as: UTF8.self)
        #expect(sanitizedBText.contains("xmlns=\"http://www.w3.org/1999/xhtml\""))
        #expect(sanitizedBText.contains("http-equiv=\"Content-Security-Policy\""))
        #expect(sanitizedBText.contains("img-src yjepub:"))
        #expect(sanitizedBText.contains("id=\"hb\""))
        #expect(sanitizedBText.contains("<span id=\"yj-t0\">Part B &amp; &lt;1&gt;</span>"))
        #expect(sanitizedBText.contains("<style data-yj-author-style=\"true\">"))
        #expect(sanitizedBText.contains("data-yj-layout=\"original\""))
        #expect(sanitizedBText.contains("color: #111"))
        #expect(!sanitizedBText.contains("<style>body"))
        #expect(!sanitizedBText.contains("<link"))

        let epub2Chapters = [
            EPUBSyntheticChapter(id: "item-c", path: "Text/partC.xhtml", title: "Part C", headingID: "hc"),
            EPUBSyntheticChapter(id: "item-b", path: "Text/partB.xhtml", title: "Part B", headingID: "hb"),
            EPUBSyntheticChapter(id: "item-a", path: "Text/partA.xhtml", title: "Part A", headingID: "ha")
        ]
        let epub2URL = root.appendingPathComponent("book2.epub")
        try EPUBTestSupport.writeEPUB2(
            at: epub2URL,
            title: "EPUB2 传统容器回归",
            chapters: epub2Chapters,
            spineOrder: ["item-c", "item-b", "item-a"],
            coverData: jpg
        )
        let dest2 = root.appendingPathComponent("dest2", isDirectory: true)
        let pkg2 = try EPUBPackageParser.parse(archiveURL: epub2URL, destination: dest2)
        #expect(pkg2.title == "EPUB2 传统容器回归")
        #expect(pkg2.spine == ["OEBPS/Text/partC.xhtml", "OEBPS/Text/partB.xhtml", "OEBPS/Text/partA.xhtml"])
        #expect(pkg2.coverPath == "OEBPS/images/cover.jpg")
        #expect(pkg2.navigation.count == 3)
        try expectCorrectedRasterResources()
    }

    @Test func epubPackageResolvesNavAndNCXHierarchyWithValidatedFragments() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let chapters = [
            EPUBSyntheticChapter(
                id: "c1",
                path: "Text/ch 1.xhtml",
                title: "卷一",
                headingID: "sec-1",
                bodyXHTML: """
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>卷一</title></head><body><h1 id="sec-1">卷一</h1><h2 id="sub-1">第一节</h2><p>内容一</p></body></html>
                """
            ),
            EPUBSyntheticChapter(
                id: "c2",
                path: "Text/ch2.xhtml",
                title: "卷二",
                headingID: "sec-2",
                bodyXHTML: """
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>卷二</title></head><body><h1 id="sec-2">卷二</h1><p>内容二</p></body></html>
                """
            )
        ]

        let navXHTML = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>TOC</title></head><body>
        <nav epub:type="toc"><ol>
        <li><a href="Text/ch%201.xhtml#sec-1">卷一 起点</a><ol><li><a href="Text/ch%201.xhtml#sub-1">第一节 细分</a></li></ol></li>
        <li><a href="./Text/ch2.xhtml">卷二 全文</a></li>
        </ol></nav></body></html>
        """
        let epub3URL = root.appendingPathComponent("nav-hierarchy.epub")
        try EPUBTestSupport.writeEPUB3(at: epub3URL, chapters: chapters, navXHTML: navXHTML)
        let dest3 = root.appendingPathComponent("dest-nav3", isDirectory: true)
        let pkg3 = try EPUBPackageParser.parse(archiveURL: epub3URL, destination: dest3)
        #expect(pkg3.navigation == [
            EPUBNavigationItem(title: "卷一 起点", path: "OPS/Text/ch 1.xhtml", fragment: "sec-1", depth: 0),
            EPUBNavigationItem(title: "第一节 细分", path: "OPS/Text/ch 1.xhtml", fragment: "sub-1", depth: 1),
            EPUBNavigationItem(title: "卷二 全文", path: "OPS/Text/ch2.xhtml", fragment: nil, depth: 0)
        ])

        let ncxXML = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        <navPoint id="p1"><navLabel><text>卷一 NCX</text></navLabel><content src="Text/ch%201.xhtml#sec-1"/>
        <navPoint id="p1-1"><navLabel><text>子节 NCX</text></navLabel><content src="Text/ch%201.xhtml#sub-1"/></navPoint>
        </navPoint>
        <navPoint id="p2"><navLabel><text>卷二 NCX</text></navLabel><content src="Text/ch2.xhtml#sec-2"/></navPoint>
        </navMap></ncx>
        """
        let epub2URL = root.appendingPathComponent("ncx-hierarchy.epub")
        try EPUBTestSupport.writeEPUB2(at: epub2URL, chapters: chapters, ncxXML: ncxXML)
        let dest2 = root.appendingPathComponent("dest-ncx2", isDirectory: true)
        let pkg2 = try EPUBPackageParser.parse(archiveURL: epub2URL, destination: dest2)
        #expect(pkg2.navigation == [
            EPUBNavigationItem(title: "卷一 NCX", path: "OEBPS/Text/ch 1.xhtml", fragment: "sec-1", depth: 0),
            EPUBNavigationItem(title: "子节 NCX", path: "OEBPS/Text/ch 1.xhtml", fragment: "sub-1", depth: 1),
            EPUBNavigationItem(title: "卷二 NCX", path: "OEBPS/Text/ch2.xhtml", fragment: "sec-2", depth: 0)
        ])

        // Broken optional navigation falls back to verified spine; no chapter is dropped.
        for badHref in ["Text/ch2.xhtml#missing-frag", "nav.xhtml", "../outside.xhtml"] {
            let badNav = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"\(badHref)\">Bad</a></li></ol></nav></body></html>"
            let badURL = root.appendingPathComponent(UUID().uuidString + ".epub")
            try EPUBTestSupport.writeEPUB3(at: badURL, chapters: chapters, navXHTML: badNav)
            let badDest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let degraded = try EPUBPackageParser.parse(archiveURL: badURL, destination: badDest)
            #expect(degraded.navigation.map(\.path) == degraded.spine)
            #expect(degraded.navigation.allSatisfy { $0.fragment == nil })
            #expect(degraded.styleCompatibility?.issues.contains(.navigationUnavailable) == true)
        }
    }

    @Test func epubPackageRejectsXXEDTDAndEntityDeclarationsAcrossUTF8AndUTF16() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let xxeXHTML = """
        <?xml version="1.0"?>
        <!DOCTYPE html [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>XXE</title></head><body><p>&xxe;</p></body></html>
        """
        let billionLaughs = """
        <?xml version="1.0"?>
        <!DOCTYPE html [ <!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;"> ]>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Entity</title></head><body><p>&lol2;</p></body></html>
        """
        let externalDTD = """
        <?xml version="1.0"?>
        <!DOCTYPE html SYSTEM "http://example.com/evil.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>DTD</title></head><body><p>Text</p></body></html>
        """

        let encodedPayloads: [Data] = [
            Data(xxeXHTML.utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data(xxeXHTML.utf8),
            EPUBTestSupport.encodeUTF16(xxeXHTML, bigEndian: false, includeBOM: true),
            EPUBTestSupport.encodeUTF16(xxeXHTML, bigEndian: true, includeBOM: true),
            EPUBTestSupport.encodeUTF16(billionLaughs, bigEndian: false, includeBOM: false),
            EPUBTestSupport.encodeUTF16(externalDTD, bigEndian: true, includeBOM: false)
        ]

        for payload in encodedPayloads {
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            #expect(throws: EPUBError.invalidPackage) {
                _ = try EPUBContentPolicy.sanitizeXHTML(
                    data: payload,
                    path: "OPS/one.xhtml",
                    manifestByPath: ["OPS/one.xhtml": "application/xhtml+xml"],
                    spineSet: ["OPS/one.xhtml"],
                    destination: dest
                )
            }
        }

        // Also verify UTF-16LE DTD inside container.xml or OPF is rejected by full EPUBPackageParser.parse.
        let utf16OPFWithDTD = EPUBTestSupport.encodeUTF16(
            """
            <?xml version="1.0" encoding="UTF-16"?>
            <!DOCTYPE package [ <!ENTITY t "Title"> ]>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata><title>&t;</title></metadata><manifest/><spine/></package>
            """,
            bigEndian: false,
            includeBOM: true
        )
        let badArchive = root.appendingPathComponent("utf16-dtd-opf.epub")
        try EPUBTestSupport.writeZIP(
            at: badArchive,
            entries: [
                ("mimetype", Data("application/epub+zip".utf8), .none),
                ("META-INF/container.xml", Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8), .deflate),
                ("OPS/book.opf", utf16OPFWithDTD, .deflate)
            ]
        )
        let badDest = root.appendingPathComponent("bad-opf-dest", isDirectory: true)
        #expect(throws: EPUBError.invalidPackage) {
            _ = try EPUBPackageParser.parse(archiveURL: badArchive, destination: badDest)
        }
        let body = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p><![CDATA[A😀e\u{301} <plain>]]></p></body></html>"
        let sanitized = try EPUBContentPolicy.sanitizeXHTML(data: Data(body.utf8), path: "OPS/one.xhtml",
            manifestByPath: ["OPS/one.xhtml": "application/xhtml+xml"], spineSet: ["OPS/one.xhtml"], destination: root)
        #expect(sanitized.textNodes == ["A😀e\u{301} <plain>"])
        let deep = "<html><body>" + String(repeating: "<div>", count: 130) + "text"
            + String(repeating: "</div>", count: 130) + "</body></html>"
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBContentPolicy.sanitizeXHTML(data: Data(deep.utf8), path: "OPS/one.xhtml",
                manifestByPath: ["OPS/one.xhtml": "application/xhtml+xml"], spineSet: ["OPS/one.xhtml"], destination: root)
        }
    }

    @Test func epubPackageRejectsMissingMetadataEmptyBodyAndDuplicateManifestItems() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        // 1. Missing title
        let noTitleURL = root.appendingPathComponent("no-title.epub")
        try EPUBTestSupport.writeEPUB3(at: noTitleURL, title: "   ")
        // 2. Empty spine
        let emptySpineURL = root.appendingPathComponent("empty-spine.epub")
        try EPUBTestSupport.writeEPUB3(at: emptySpineURL, spineOrder: [])
        // 3. Duplicate manifest ID
        let dupIDURL = root.appendingPathComponent("dup-id.epub")
        try EPUBTestSupport.writeEPUB3(
            at: dupIDURL,
            manifestExtra: "<item id=\"ch1\" href=\"other.xhtml\" media-type=\"application/xhtml+xml\"/>"
        )
        // 4. Duplicate canonical href
        let dupHrefURL = root.appendingPathComponent("dup-href.epub")
        try EPUBTestSupport.writeEPUB3(
            at: dupHrefURL,
            manifestExtra: "<item id=\"dup\" href=\"./one.xhtml\" media-type=\"application/xhtml+xml\"/>"
        )
        // 5. Empty body text in spine XHTML
        let emptyBodyURL = root.appendingPathComponent("empty-body.epub")
        try EPUBTestSupport.writeEPUB3(
            at: emptyBodyURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "ch1",
                    path: "one.xhtml",
                    title: "Empty",
                    bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Empty</title></head><body><div id=\"heading\">   </div></body></html>"
                )
            ]
        )
        // 6. Reserved yj-t fragment ID prefix collision
        let prefixCollisionURL = root.appendingPathComponent("yj-collision.epub")
        try EPUBTestSupport.writeEPUB3(
            at: prefixCollisionURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "ch1",
                    path: "one.xhtml",
                    title: "Collision",
                    bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>C</title></head><body><h1 id=\"heading\">C</h1><p id=\"yj-t0\">Collision</p></body></html>"
                )
            ]
        )

        let untitled = try EPUBPackageParser.parse(archiveURL: noTitleURL, destination: root.appendingPathComponent("untitled"))
        #expect(untitled.title == "未命名书籍")
        let blank = try EPUBPackageParser.parse(archiveURL: emptyBodyURL, destination: root.appendingPathComponent("blank"))
        #expect(blank.spine == ["OPS/one.xhtml"])
        #expect(blank.textNodes["OPS/one.xhtml"] == ["空白页"])
        for url in [emptySpineURL, dupIDURL, dupHrefURL, prefixCollisionURL] {
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.invalidPackage) {
                _ = try EPUBPackageParser.parse(archiveURL: url, destination: dest)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        }

        // Spine item count limit
        let validURL = root.appendingPathComponent("spine-limit.epub")
        try EPUBTestSupport.writeEPUB3(at: validURL)
        var spineLimit = EPUBLimits()
        spineLimit.spineItems = 1
        let limitDest = root.appendingPathComponent("limit-dest", isDirectory: true)
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBPackageParser.parse(archiveURL: validURL, destination: limitDest, limits: spineLimit)
        }
    }

    @Test func epubPackageRejectsBrokenSpineAndBodyResourceReferences() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        // 1. Spine references unknown manifest ID
        let unknownSpineURL = root.appendingPathComponent("unknown-spine.epub")
        try EPUBTestSupport.writeEPUB3(at: unknownSpineURL, spineOrder: ["ch1", "nonexistent"])

        // 2. Body <img> not in manifest
        let unmanifestedImgURL = root.appendingPathComponent("unmanifested-img.epub")
        try EPUBTestSupport.writeEPUB3(
            at: unmanifestedImgURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "ch1",
                    path: "one.xhtml",
                    title: "Img",
                    bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><h1 id=\"heading\">T</h1><p>Text</p><img src=\"ghost.png\"/></body></html>"
                )
            ]
        )

        // 3. Body <a> references non-spine file
        let badLinkFileURL = root.appendingPathComponent("bad-link-file.epub")
        try EPUBTestSupport.writeEPUB3(
            at: badLinkFileURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "ch1",
                    path: "one.xhtml",
                    title: "Link",
                    bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><h1 id=\"heading\">T</h1><p><a href=\"missing.xhtml\">Bad</a></p></body></html>"
                )
            ]
        )

        // 4. Body <a> references missing fragment in valid spine chapter
        let badLinkFragURL = root.appendingPathComponent("bad-link-frag.epub")
        try EPUBTestSupport.writeEPUB3(
            at: badLinkFragURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "ch1",
                    path: "one.xhtml",
                    title: "Link",
                    bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><h1 id=\"heading\">T</h1><p><a href=\"one.xhtml#no-such-id\">Bad</a></p></body></html>"
                )
            ]
        )

        for url in [badLinkFileURL, badLinkFragURL] {
            let dest = root.appendingPathComponent(UUID().uuidString)
            let degraded = try EPUBPackageParser.parse(archiveURL: url, destination: dest)
            #expect(degraded.textNodes["OPS/one.xhtml"] == ["T", "Bad"])
            #expect(degraded.styleCompatibility?.issues.contains(.navigationUnavailable) == true)
            let data = try EPUBResourceStore.data(path: "OPS/one.xhtml", publication: EPUBPublication(package: degraded, resourceRoot: dest))
            #expect(!String(decoding: data, as: UTF8.self).contains(" href="))
        }
        for url in [unknownSpineURL, unmanifestedImgURL] {
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.invalidPackage) {
                _ = try EPUBPackageParser.parse(archiveURL: url, destination: dest)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        }
    }

    @Test func epubPackageRejectsEncryptedFixedLayoutAndActiveContent() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        // 1. META-INF/encryption.xml present
        let drmURL = root.appendingPathComponent("drm.epub")
        try EPUBTestSupport.writeEPUB3(
            at: drmURL,
            extraEntries: [("META-INF/encryption.xml", Data("<encryption/>".utf8))]
        )

        // 2. Fixed-layout OPF metadata
        let fixedMetaURL = root.appendingPathComponent("fixed-meta.epub")
        try EPUBTestSupport.writeEPUB3(
            at: fixedMetaURL,
            metadataExtra: "<meta property=\"rendition:layout\">pre-paginated</meta>"
        )

        // 3. Fixed-layout spine itemref property
        let fixedSpineURL = root.appendingPathComponent("fixed-spine.epub")
        try EPUBTestSupport.writeEPUB3(
            at: fixedSpineURL,
            spineItemProperties: ["ch1": "rendition:layout-pre-paginated"]
        )

        for url in [drmURL, fixedMetaURL, fixedSpineURL] {
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBPackageParser.parse(archiveURL: url, destination: dest)
            }
        }

        // 4. Active/unsupported XHTML, event handlers, and external URLs remain fatal.
        let forbiddenSnippets = [
            "<script>alert(1)</script><p>Text</p>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg><p>Text</p>",
            "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math><p>Text</p>",
            "<video src=\"a.mp4\"/><p>Text</p>",
            "<audio src=\"a.mp3\"/><p>Text</p>",
            "<form><input type=\"text\"/></form><p>Text</p>",
            "<iframe src=\"two.xhtml\"/><p>Text</p>",
            "<object data=\"a.swf\"/><p>Text</p>",
            "<p onclick=\"alert(1)\">Click</p>",
            "<p><a href=\"javascript:alert(1)\">JS</a></p>",
            "<p><img src=\"https://example.com/pic.png\"/></p>",
            "<style>@font-face { font-family: Custom; src: url(https://example.com/f.woff); }</style><p>Text</p>"
        ]

        for snippet in forbiddenSnippets {
            let body = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><h1 id=\"heading\">T</h1>\(snippet)</body></html>"
            let url = root.appendingPathComponent(UUID().uuidString + ".epub")
            try EPUBTestSupport.writeEPUB3(
                at: url,
                chapters: [EPUBSyntheticChapter(id: "ch1", path: "one.xhtml", title: "T", bodyXHTML: body)]
            )
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBPackageParser.parse(archiveURL: url, destination: dest)
            }
        }

        // Missing local WOFF is optional styling, never a served font capability.
        let optionalURL = root.appendingPathComponent("optional-woff.epub")
        let optionalBody = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><h1 id=\"heading\">T</h1><style>@font-face { font-family: Custom; src: url(f.woff); }</style><p>Text</p></body></html>"
        try EPUBTestSupport.writeEPUB3(at: optionalURL, chapters: [
            EPUBSyntheticChapter(id: "ch1", path: "one.xhtml", title: "T", bodyXHTML: optionalBody)
        ])
        let optionalDest = root.appendingPathComponent("optional-woff", isDirectory: true)
        let optional = try EPUBPackageParser.parse(archiveURL: optionalURL, destination: optionalDest)
        #expect(optional.resource(at: "OPS/f.woff") == nil)
        #expect(optional.styleCompatibility?.issues.contains(.fontUnavailable) == true)
        #expect(try optional.nodes(at: "OPS/one.xhtml")?.joined().contains("Text") == true)
        let sanitized = try String(contentsOf: optionalDest.appendingPathComponent("OPS/one.xhtml"), encoding: .utf8)
        #expect(!sanitized.contains("f.woff"))
        #expect(!sanitized.contains("@font-face"))
    }

    @Test func epubPackageSelectsValidCoversAndFallsBackOnOptionalCoverProblems() async throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let validPNG = try EPUBTestSupport.pngData(width: 900, height: 600)
        let validJPG = try EPUBTestSupport.jpegData(width: 600, height: 900)

        // 1. Valid EPUB3 PNG cover
        let epub3CoverURL = root.appendingPathComponent("cover3.epub")
        try EPUBTestSupport.writeEPUB3(at: epub3CoverURL, coverData: validPNG, coverHref: "cover.png", coverMediaType: "image/png")
        let dest3 = root.appendingPathComponent("dest3", isDirectory: true)
        let pkg3 = try EPUBPackageParser.parse(archiveURL: epub3CoverURL, destination: dest3)
        #expect(pkg3.coverPath == "OPS/cover.png")
        #expect(pkg3.resource(at: "OPS/cover.png")?.mediaType == "image/png")
        let thumb3 = try #require(await EPUBCoverProcessor.shared.thumbnail(validPNG))
        let src3 = try #require(CGImageSourceCreateWithData(thumb3 as CFData, nil))
        let props3 = try #require(CGImageSourceCopyPropertiesAtIndex(src3, 0, nil) as? [CFString: Any])
        #expect((props3[kCGImagePropertyPixelWidth] as? Int) == 512)

        // 2. Valid EPUB2 JPEG cover via <meta name="cover" content="cover-img"/>
        let epub2CoverURL = root.appendingPathComponent("cover2.epub")
        try EPUBTestSupport.writeEPUB2(at: epub2CoverURL, coverData: validJPG)
        let dest2 = root.appendingPathComponent("dest2", isDirectory: true)
        let pkg2 = try EPUBPackageParser.parse(archiveURL: epub2CoverURL, destination: dest2)
        #expect(pkg2.coverPath == "OEBPS/images/cover.jpg")
        #expect(pkg2.resource(at: "OEBPS/images/cover.jpg")?.mediaType == "image/jpeg")

        // 3. Optional cover declared with unsupported mediaType (image/gif) or missing file falls back to nil coverPath
        let gifCoverURL = root.appendingPathComponent("gif-cover.epub")
        try EPUBTestSupport.writeEPUB3(
            at: gifCoverURL,
            coverData: Data("GIF89a".utf8),
            coverHref: "cover.gif",
            coverMediaType: "image/gif"
        )
        let gifDest = root.appendingPathComponent("gif-dest", isDirectory: true)
        let gifPkg = try EPUBPackageParser.parse(archiveURL: gifCoverURL, destination: gifDest)
        #expect(gifPkg.coverPath == nil)

        let danglingMetaCoverURL = root.appendingPathComponent("dangling-cover.epub")
        try EPUBTestSupport.writeEPUB3(
            at: danglingMetaCoverURL,
            metadataExtra: "<meta name=\"cover\" content=\"missing-cover-id\"/>"
        )
        let danglingDest = root.appendingPathComponent("dangling-dest", isDirectory: true)
        let danglingPkg = try EPUBPackageParser.parse(archiveURL: danglingMetaCoverURL, destination: danglingDest)
        #expect(danglingPkg.coverPath == nil)

        // 4. Corrupt optional cover bytes do not abort package parsing; thumbnail processor returns nil
        let corruptCoverURL = root.appendingPathComponent("corrupt-optional-cover.epub")
        let corruptBytes = Data("not-a-valid-png-cover".utf8)
        try EPUBTestSupport.writeEPUB3(at: corruptCoverURL, coverData: corruptBytes)
        let corruptDest = root.appendingPathComponent("corrupt-dest", isDirectory: true)
        let corruptPkg = try EPUBPackageParser.parse(archiveURL: corruptCoverURL, destination: corruptDest)
        #expect(corruptPkg.spine == ["OPS/one.xhtml", "OPS/two.xhtml"])
        #expect(await EPUBCoverProcessor.shared.thumbnail(corruptBytes) == nil)
    }

    @Test func epubPackageFailsFatallyOnCorruptBodyImageOrArchiveIntegrityError() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        // 1. Corrupt PNG referenced by <img> in spine XHTML body must fail fatally with .corruptResource.
        let corruptBodyImgURL = root.appendingPathComponent("corrupt-body-img.epub")
        try EPUBTestSupport.writeEPUB3(
            at: corruptBodyImgURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "ch1",
                    path: "one.xhtml",
                    title: "BodyImg",
                    bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><h1 id=\"heading\">T</h1><p>Body</p><p><img src=\"bad.png\"/></p></body></html>"
                )
            ],
            manifestExtra: "<item id=\"badimg\" href=\"bad.png\" media-type=\"image/png\"/>",
            extraEntries: [("OPS/bad.png", Data("corrupt-png-bytes".utf8))]
        )
        let dest1 = root.appendingPathComponent("dest1", isDirectory: true)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBPackageParser.parse(archiveURL: corruptBodyImgURL, destination: dest1)
        }
        #expect(!FileManager.default.fileExists(atPath: dest1.path))

        // 2. Bad ZIP CRC on optional cover entry must NOT be swallowed by cover fallback.
        let validPNG = try EPUBTestSupport.pngData()
        let crcArchiveURL = root.appendingPathComponent("crc-cover.epub")
        try EPUBTestSupport.writeEPUB3(
            at: crcArchiveURL,
            coverData: validPNG,
            compress: false
        )
        var rawBytes = try Data(contentsOf: crcArchiveURL)
        EPUBTestSupport.corruptFirstEntryCRC(&rawBytes)
        try rawBytes.write(to: crcArchiveURL)
        let dest2 = root.appendingPathComponent("dest2", isDirectory: true)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBPackageParser.parse(archiveURL: crcArchiveURL, destination: dest2)
        }
        #expect(!FileManager.default.fileExists(atPath: dest2.path))
        try expectInvalidRasterCorrectionsRejected()
    }
    private func writeRasterEPUB(at url: URL, data: Data, declared: String) throws {
        let body = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Synthetic</title></head><body><h1 id=\"heading\">Synthetic</h1><img src=\"cover.png\"/></body></html>"
        try EPUBTestSupport.writeEPUB3(at: url,
            chapters: [EPUBSyntheticChapter(id: "one", path: "one.xhtml", title: "Synthetic", bodyXHTML: body)],
            coverData: data, coverHref: "cover.png", coverMediaType: declared)
    }

    private func expectCorrectedRasterResources() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, String, Data)] = [
            ("image/png", "image/jpeg", try EPUBTestSupport.jpegData(width: 2, height: 2)),
            ("image/jpeg", "image/png", try EPUBTestSupport.pngData(width: 2, height: 2))
        ]
        for (index, value) in cases.enumerated() {
            let (declared, actual, data) = value
            // The general validator stays strict. Correction belongs to bounded import only.
            #expect(throws: EPUBError.corruptResource) { try EPUBContentPolicy.verifyImageData(data, mediaType: declared) }
            #expect(EPUBCompatibility.rasterMediaTypeCorrection(for: data, declared: declared) == actual)
            let archive = root.appendingPathComponent("mismatch-\(index).epub")
            try writeRasterEPUB(at: archive, data: data, declared: declared)
            let original = try Data(contentsOf: archive)
            let destination = root.appendingPathComponent("mismatch-\(index)", isDirectory: true)
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
            let restored = try JSONDecoder().decode(EPUBPackage.self, from: JSONEncoder().encode(package))
            #expect(restored == package)
            let resource = try #require(restored.resource(at: "OPS/cover.png"))
            #expect(resource.mediaType == actual)
            #expect(resource.byteCount == data.count && resource.sha256 == EPUBResourceStore.digest(data))
            #expect(restored.coverPath == "OPS/cover.png")
            let publication = EPUBPublication(package: restored, resourceRoot: destination)
            #expect(try EPUBResourceStore.data(path: resource.path, publication: publication) == data)
            #expect(try Data(contentsOf: archive) == original)
            let imageURL = destination.appendingPathComponent(resource.path)
            var tampered = data; tampered[tampered.count - 1] ^= 1
            for invalid in [tampered, Data(data.dropLast())] {
                try invalid.write(to: imageURL)
                #expect(throws: EPUBError.corruptResource) { _ = try EPUBResourceStore.data(path: resource.path, publication: publication) }
            }
        }
    }

    private func expectInvalidRasterCorrectionsRejected() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try EPUBTestSupport.jpegData(width: 2, height: 2)
        // Independently generated 2x2 two-frame PNG; never silently flatten it.
        let animatedPNG = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAACAAAAAgAAAAAAAAAAAAEACgAA6FTcAAAAABBJREFUeJxj/M8AAkxgkgEADR0BA4LJcf8AAAAaZmNUTAAAAAEAAAACAAAAAgAAAAAAAAAAAAEACgAAcyc21AAAABZmZEFUAAAAAnicY2Rg+M/AwMDEAAYACx8BAyVgX34AAAAASUVORK5CYII="))
        let invalid: [(String, Data)] = [
            ("image/jpeg", animatedPNG),
            ("image/png", Data([0xFF, 0xD8, 0xFF])),
            ("image/png", Data(jpeg.prefix(32))),
            ("image/jpeg", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            ("image/png", Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script/></svg>".utf8)),
            ("image/webp", jpeg)
        ]
        for (index, value) in invalid.enumerated() {
            let archive = root.appendingPathComponent("invalid-\(index).epub")
            try writeRasterEPUB(at: archive, data: value.1, declared: value.0)
            let destination = root.appendingPathComponent("invalid-\(index)", isDirectory: true)
            #expect(throws: EPUBError.corruptResource) { _ = try EPUBPackageParser.parse(archiveURL: archive, destination: destination) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(EPUBCompatibility.rasterMediaTypeCorrection(for: jpeg, declared: "image/svg+xml") == nil)
        #expect(EPUBCompatibility.rasterMediaTypeCorrection(for: jpeg, declared: "image/webp") == nil)
        let oversized = try EPUBTestSupport.pngData(width: 16_385, height: 1)
        #expect(throws: EPUBError.limitExceeded) { try EPUBCompatibility.verifyCorrectedRaster(oversized, mediaType: "image/png") }
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBCompatibility.verifyCorrectedRaster(Data(repeating: 0, count: EPUBLimits().imageBytes + 1), mediaType: "image/jpeg")
        }
    }
}
