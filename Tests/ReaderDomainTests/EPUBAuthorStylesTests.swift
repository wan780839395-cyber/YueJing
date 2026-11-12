import CryptoKit
import Foundation
import Testing
@testable import ReaderDomain

struct EPUBAuthorStylesTests {
    @Test func authorStylesSanitizesExternalInlineAndClassCSSWithScopedSelectors() throws {
        #expect(EPUBAuthorStyles.rootRelativeEncodedPath(for: "OPS/Fonts/a'b(c).ttf") == "/OPS/Fonts/a%27b%28c%29.ttf")
        #expect(EPUBAuthorStyles.rootRelativeEncodedPath(for: "OPS/Fonts/a b.ttf") == "/OPS/Fonts/a%20b.ttf")
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try EPUBTestSupport.pngData(width: 16, height: 16)
        let externalCSS = """
        @charset "UTF-8";
        /* Book typography */
        html { font-size: 16px; }
        body.book-body { color: #222222; background-color: rgb(250, 248, 240); margin: 0 12px; }
        h1#title { font-size: 1.5em; font-weight: 700; text-align: center; border-bottom: 1px solid rgba(0, 0, 0, 0.2); }
        div.box > p.lead { text-indent: 2em; line-height: 1.6; padding: 4px 8px; color: hsl(210, 50%, 30%); }
        img.fig { width: 80%; max-width: 320px; height: auto; float: left; clear: both; }
        """
        let chapterXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Styled Chapter</title>
            <link rel="stylesheet" type="text/css" href="../Styles/book.css"/>
            <style type="text/css">
                p.note { font-style: italic; margin-top: 8px; }
            </style>
        </head>
        <body id="doc-body" class="book-body yj-spoof" style="padding: 6px;">
            <h1 id="title">Title &amp; Heading</h1>
            <div class="box">
                <p class="lead" style="color: #aa1122; text-indent: 1em;">First line.</p>
                <p class="note">Second line.</p>
                <p><img class="fig" src="../Images/fig.png" alt="Figure" style="border: 2px solid #333;"/></p>
            </div>
        </body>
        </html>
        """
        let plainBaselineXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Styled Chapter</title></head>
        <body id="doc-body">
            <h1 id="title">Title &amp; Heading</h1>
            <div class="box">
                <p class="lead">First line.</p>
                <p class="note">Second line.</p>
                <p><img class="fig" src="../Images/fig.png" alt="Figure"/></p>
            </div>
        </body>
        </html>
        """

        let epubURL = root.appendingPathComponent("styled.epub")
        try EPUBTestSupport.writeEPUB3(
            at: epubURL,
            chapters: [
                EPUBSyntheticChapter(id: "c1", path: "Text/ch1.xhtml", title: "Styled Chapter", headingID: "title", bodyXHTML: chapterXHTML)
            ],
            manifestExtra: """
            <item id="css1" href="Styles/book.css" media-type="text/css"/>
            <item id="fig1" href="Images/fig.png" media-type="image/png"/>
            """,
            extraEntries: [
                ("OPS/Styles/book.css", Data(externalCSS.utf8)),
                ("OPS/Images/fig.png", png)
            ]
        )

        let dest = root.appendingPathComponent("parsed", isDirectory: true)
        let package = try EPUBPackageParser.parse(archiveURL: epubURL, destination: dest)

        // External CSS must be inlined/sanitized and NOT stored as a served resource or left on disk.
        #expect(package.resources.map(\.path) == ["OPS/Text/ch1.xhtml", "OPS/Images/fig.png"])
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("OPS/Styles/book.css").path))

        // Text nodes & yj-tN numbering must remain identical to unstyled XHTML.
        let baseline = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(plainBaselineXHTML.utf8),
            path: "OPS/Text/ch1.xhtml",
            manifestByPath: ["OPS/Text/ch1.xhtml": "application/xhtml+xml", "OPS/Images/fig.png": "image/png"],
            spineSet: ["OPS/Text/ch1.xhtml"],
            destination: dest
        )
        #expect(package.textNodes["OPS/Text/ch1.xhtml"] == baseline.textNodes)
        #expect(package.textNodes["OPS/Text/ch1.xhtml"] == ["Title & Heading", "First line.", "Second line."])

        let sanitizedBytes = try Data(contentsOf: dest.appendingPathComponent("OPS/Text/ch1.xhtml"))
        let sanitizedText = String(decoding: sanitizedBytes, as: UTF8.self)
        let expectedScope = EPUBAuthorStyles.scopeIdentifier(for: "OPS/Text/ch1.xhtml")
        #expect(expectedScope.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0)) })
        #expect(sanitizedText.contains("<body data-yj-author-scope=\"\(expectedScope)\""))
        #expect(sanitizedText.contains("class=\"book-body yj-i-0\""))
        #expect(!sanitizedText.contains("yj-spoof"))
        #expect(!sanitizedText.contains(" style=\""))
        #expect(!sanitizedText.contains("<link"))
        #expect(sanitizedText.contains("<span id=\"yj-t0\">Title &amp; Heading</span>"))
        #expect(sanitizedText.contains("<span id=\"yj-t1\">First line.</span>"))
        #expect(sanitizedText.contains("<span id=\"yj-t2\">Second line.</span>"))

        let extractedStyle = try extractAuthorStyleFromXHTML(sanitizedBytes)
        #expect(extractedStyle.contains("html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(expectedScope)\"] { font-size: 16px; }"))
        #expect(extractedStyle.contains("html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(expectedScope)\"].book-body { color: #222222;"))
        #expect(extractedStyle.contains(":is([data-yj-original-id=\"title\"], #yj-id-specificity:not(*))"))
        #expect(!extractedStyle.contains("#title"))
        #expect(extractedStyle.contains("div.box > p.lead"))
        #expect(extractedStyle.contains("float: left"))
        #expect(extractedStyle.contains("max-width: 320px"))
        #expect(extractedStyle.contains("html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(expectedScope)\"].yj-i-0:not(#yj-inline-a#yj-inline-b) { padding: 6px; }"))
        #expect(extractedStyle.contains("html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(expectedScope)\"] .yj-i-1:not(#yj-inline-a#yj-inline-b) { color: #aa1122; text-indent: 1em; }"))
        #expect(extractedStyle.contains("html[data-yj-layout=\"original\"] [data-yj-author-scope=\"\(expectedScope)\"] .yj-i-2:not(#yj-inline-a#yj-inline-b) { border: 2px solid #333; }"))

        // Also confirm UTF-16LE external CSS BOM decoding works.
        let utf16CSS = EPUBTestSupport.encodeUTF16("p { color: #123456; }", bigEndian: false, includeBOM: true)
        let utf16Dir = root.appendingPathComponent("utf16css", isDirectory: true)
        try FileManager.default.createDirectory(at: utf16Dir.appendingPathComponent("OPS/Styles"), withIntermediateDirectories: true)
        try utf16CSS.write(to: utf16Dir.appendingPathComponent("OPS/Styles/u16.css"))
        let u16XHTML = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="Styles/u16.css"/></head><body><p>OK</p></body></html>
        """
        let u16Doc = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(u16XHTML.utf8),
            path: "OPS/page.xhtml",
            manifestByPath: ["OPS/page.xhtml": "application/xhtml+xml", "OPS/Styles/u16.css": "text/css"],
            spineSet: ["OPS/page.xhtml"],
            destination: utf16Dir
        )
        let u16Style = try extractAuthorStyleFromXHTML(u16Doc.xhtmlData)
        #expect(u16Style.contains("color: #123456"))
    }

    @Test func authorStylesEmbedsManifestFontsAndIsolatesChapters() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let ttfData = makeMinimalSFNT(flavor: .ttf)
        let otfData = makeMinimalSFNT(flavor: .otf)
        #expect(try EPUBAuthorStyles.verifyFontData(ttfData, declaredMediaType: "font/ttf") == "font/ttf")
        #expect(try EPUBAuthorStyles.verifyFontData(ttfData, declaredMediaType: "application/font-sfnt") == "font/ttf")
        #expect(try EPUBAuthorStyles.verifyFontData(otfData, declaredMediaType: "font/otf") == "font/otf")
        #expect(try EPUBAuthorStyles.verifyFontData(otfData, declaredMediaType: "application/vnd.ms-opentype") == "font/otf")
        #expect(EPUBAuthorStyles.allowedFontMediaTypes == ["font/ttf", "font/otf"])
        #expect(EPUBAuthorStyles.maximumServedBytes(forMediaType: "font/ttf") == 8 * 1024 * 1024)
        #expect(EPUBAuthorStyles.maximumServedBytes(forMediaType: "font/otf") == 8 * 1024 * 1024)
        #expect(EPUBAuthorStyles.maximumServedBytes(forMediaType: "text/css") == nil)

        // Chapter 1 references TTF via external CSS (forward @font-face after rule + font shorthand).
        let ch1CSS = """
        p.poem { font: italic 1.1em/1.5 "SharedBookFont", Georgia, serif; }
        @font-face {
            font-family: "SharedBookFont";
            src: url("../Fonts/Book%20A.ttf") format("truetype");
            font-style: italic;
            font-weight: 400;
        }
        """
        let ch1XHTML = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Ch1</title><link rel="stylesheet" href="../Styles/ch1.css"/></head>
        <body><h1 id="heading">Chapter 1</h1><p class="poem" style="font-family: 'SharedBookFont', serif;">Poem one</p></body>
        </html>
        """
        // Chapter 2 uses the SAME author font-family name, class, and ID, backed by a different OTF font.
        let ch2XHTML = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Ch2</title>
            <style>
                @font-face { font-family: SharedBookFont; src: url(../Fonts/BookB.otf); }
                .poem { font-family: SharedBookFont, sans-serif; color: #004400; }
                #heading { color: #004400; }
            </style>
        </head>
        <body><h1 id="heading">Chapter 2</h1><p class="poem">Poem two</p></body>
        </html>
        """

        let epubURL = root.appendingPathComponent("fonts.epub")
        try EPUBTestSupport.writeEPUB3(
            at: epubURL,
            chapters: [
                EPUBSyntheticChapter(id: "c1", path: "Text/ch1.xhtml", title: "Ch1", headingID: "heading", bodyXHTML: ch1XHTML),
                EPUBSyntheticChapter(id: "c2", path: "Text/ch2.xhtml", title: "Ch2", headingID: "heading", bodyXHTML: ch2XHTML)
            ],
            manifestExtra: """
            <item id="css1" href="Styles/ch1.css" media-type="text/css"/>
            <item id="font1" href="Fonts/Book%20A.ttf" media-type="application/font-sfnt"/>
            <item id="font2" href="Fonts/BookB.otf" media-type="font/otf"/>
            """,
            extraEntries: [
                ("OPS/Styles/ch1.css", Data(ch1CSS.utf8)),
                ("OPS/Fonts/Book A.ttf", ttfData),
                ("OPS/Fonts/BookB.otf", otfData)
            ]
        )

        let dest = root.appendingPathComponent("parsed-fonts", isDirectory: true)
        let package = try EPUBPackageParser.parse(archiveURL: epubURL, destination: dest)
        let publication = EPUBPublication(package: package, resourceRoot: dest)

        let res1 = try #require(package.resource(at: "OPS/Fonts/Book A.ttf"))
        let res2 = try #require(package.resource(at: "OPS/Fonts/BookB.otf"))
        #expect(res1.mediaType == "font/ttf" && res1.sha256 == EPUBResourceStore.digest(ttfData))
        #expect(res2.mediaType == "font/otf" && res2.sha256 == EPUBResourceStore.digest(otfData))
        #expect(try EPUBResourceStore.data(path: "OPS/Fonts/Book A.ttf", publication: publication) == ttfData)
        #expect(try EPUBResourceStore.data(path: "OPS/Fonts/BookB.otf", publication: publication) == otfData)

        let scope1 = EPUBAuthorStyles.scopeIdentifier(for: "OPS/Text/ch1.xhtml")
        let scope2 = EPUBAuthorStyles.scopeIdentifier(for: "OPS/Text/ch2.xhtml")
        #expect(scope1 != scope2)

        let style1 = try extractAuthorStyleFromXHTML(try Data(contentsOf: dest.appendingPathComponent("OPS/Text/ch1.xhtml")))
        let style2 = try extractAuthorStyleFromXHTML(try Data(contentsOf: dest.appendingPathComponent("OPS/Text/ch2.xhtml")))

        #expect(style1.contains("url(\"/OPS/Fonts/Book%20A.ttf\") format(\"truetype\")"))
        #expect(style1.contains("font-family: \"yjfont-\(scope1)-0\""))
        #expect(style1.contains("font: italic 1.1em/1.5 \"yjfont-\(scope1)-0\", \"Georgia\", serif"))
        #expect(style1.contains(".yj-i-0:not(#yj-inline-a#yj-inline-b) { font-family: \"yjfont-\(scope1)-0\", serif; }"))
        #expect(!style1.contains("SharedBookFont"))
        #expect(!style1.contains(scope2))

        #expect(style2.contains("url(\"/OPS/Fonts/BookB.otf\") format(\"opentype\")"))
        #expect(style2.contains("font-family: \"yjfont-\(scope2)-0\""))
        #expect(style2.contains(".poem { font-family: \"yjfont-\(scope2)-0\", sans-serif; color: #004400; }"))
        #expect(style2.contains("[data-yj-original-id=\"heading\"]"))
        #expect(!style2.contains("SharedBookFont"))
        #expect(!style2.contains(scope1))

        // Tampering font file on disk must fail ResourceStore SHA check.
        let diskFontURL = dest.appendingPathComponent("OPS/Fonts/BookB.otf")
        var tampered = otfData
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: diskFontURL)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBResourceStore.data(path: "OPS/Fonts/BookB.otf", publication: publication)
        }

        // Disallowed MIME type in ResourceStore must fail even with matching bytes/hash.
        let badStoreResource = EPUBResource(path: "OPS/Fonts/Book A.ttf", mediaType: "font/woff", sha256: res1.sha256, byteCount: res1.byteCount)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBResourceStore.data(resource: badStoreResource, root: dest)
        }
    }

    @Test func authorStylesDropsUnsafeLayoutAndGuardsReaderAndLocatorNodes() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let css = """
        @keyframes spin { from { color: red; } to { color: blue; } }
        @media screen { p { color: #990000; } }
        :root { --accent: #ff0000; }
        body { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; display: none; color: #112233; }
        p { position: absolute; z-index: 9999; animation: spin 1s; transition: all 0.2s; --x: 1; color: var(--x); width: calc(10px + 2px); width: expr/*split*/ession(1); font-size: 18px; }
        span { margin-left: 40px; color: #334455; }
        #yj-t0 { color: #ff0000; }
        .yj-custom { color: #ff0000; }
        [data-yj-layout="reader"] p { color: #ff0000; }
        p:hover, p.safe { color: #445566; }
        * { margin: 0; }
        """
        let result = try EPUBAuthorStyles.sanitizeStylesheet(
            css,
            sourcePath: "OPS/Styles/test.css",
            documentPath: "OPS/Text/ch1.xhtml",
            manifestByPath: ["OPS/Styles/test.css": "text/css"],
            destination: root
        )

        #expect(result.css.contains("color: #112233"))
        #expect(result.css.contains("font-size: 18px"))
        #expect(result.css.contains("span:where(:not([id^=\"yj-t\"]):not([data-yj-original-id^=\"yj-t\"])) { margin-left: 40px; color: #334455; }"))
        #expect(result.css.contains("p.safe { color: #445566; }"))

        for forbidden in [
            "fixed", "absolute", "z-index", "animation", "transition", "@keyframes",
            "--accent", "--x", "var(", "calc(", "100vw", "100vh", "display: none",
            "yj-t0", "yj-custom", "data-yj-layout=\"reader\"", ":hover", "expression", "ession", "#ff0000"
        ] {
            #expect(!result.css.contains(forbidden), "Unexpected token leaked: \(forbidden)")
        }
    }

    @Test func authorStylesRejectsEscapedMaliciousCSSExternalURLsAndUnknownResources() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest: [String: String] = [
            "OPS/Text/ch1.xhtml": "application/xhtml+xml",
            "OPS/Styles/good.css": "text/css",
            "OPS/Fonts/valid.ttf": "font/ttf"
        ]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Fonts"), withIntermediateDirectories: true)
        try makeMinimalSFNT(flavor: .ttf).write(to: root.appendingPathComponent("OPS/Fonts/valid.ttf"))

        // 1. Escaped dangerous functions, schemes, and @import -> unsupportedContent
        let unsupportedCSSPayloads = [
            #"p { background: \75 rl(https://evil.invalid/track.png); }"#,
            #"p { background: \75rl("http://evil.invalid/track.png"); }"#,
            #"p { width: \65 xpression(alert(1)); }"#,
            #"p { background: url("\6a avascript:alert(1)"); }"#,
            #"p { background: url("java\9 script:alert(1)"); }"#,
            #"p { background: url("data:text/css,body{}"); }"#,
            #"p { background: url("yjepub://other/pic.png"); }"#,
            #"@\69 mport "https://evil.invalid/a.css";"#,
            #"@import url("https://evil.invalid/a.css");"#,
            #"p { \62 ehavior: url(good.css); }"#,
            #"p { -moz-binding: url(good.css); }"#,
            #"p { content: "unclosed"#,
            #"p { background: url(unquoted space.png); }"#,
            #"@media screen { p { background: url(https://evil.invalid/a.png); } }"#,
            #"@font-face { }"#,
            #"@font-face { font-family: Custom; }"#,
            #"@font-face { src: url(../Fonts/valid.ttf); }"#,
        ]
        for payload in unsupportedCSSPayloads {
            #expect(throws: EPUBError.unsupportedContent, "Must reject CSS: \(payload)") {
                _ = try EPUBAuthorStyles.sanitizeStylesheet(
                    payload,
                    sourcePath: "OPS/Styles/good.css",
                    documentPath: "OPS/Text/ch1.xhtml",
                    manifestByPath: manifest,
                    destination: root
                )
            }
        }

        for payload in [
            #"@font-face { font-family: Custom; src: url(f.woff); }"#,
            #"@font-face { font-family: Custom; src: url(f.woff2) format("woff2"); }"#,
            #"@font-face { font-family: Custom; \73 rc: url(f.woff); }"#
        ] {
            let result = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                payload + " p { color: #123456; }", sourcePath: "OPS/Styles/good.css",
                documentPath: "OPS/Text/ch1.xhtml", manifestByPath: manifest, destination: root
            )
            #expect(result.referencedFonts.isEmpty && !result.css.contains("@font-face"))
            #expect(result.css.contains("#123456"))
            #expect(result.styleCompatibility.issues.contains(.fontUnavailable))
        }

        // CSS \t escapes the literal letter t, not a tab: the unknown scheme is still rejected.
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                #"p { background: url("java\tscript:alert(1)"); }"#,
                sourcePath: "OPS/Styles/good.css",
                documentPath: "OPS/Text/ch1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // 2. Path traversal in CSS URL -> unsafePath
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                #"@font-face { font-family: Bad; src: url(../../../etc/passwd); }"#,
                sourcePath: "OPS/Styles/good.css",
                documentPath: "OPS/Text/ch1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // 2b. Escaped @import traversal -> unsafePath
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                #"@\69 mport "../../../outside.css";"#,
                sourcePath: "OPS/Styles/good.css",
                documentPath: "OPS/Text/ch1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // 3. Benign compatibility degradation (local-only font, missing optional font/CSS/background, self-import cycle)
        let localOnlyResult = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            #"@font-face { font-family: Custom; src: local("PingFang SC"); } p { color: #223344; }"#,
            sourcePath: "OPS/Styles/good.css",
            documentPath: "OPS/Text/ch1.xhtml",
            manifestByPath: manifest,
            destination: root
        )
        #expect(localOnlyResult.referencedFonts.isEmpty)
        #expect(!localOnlyResult.css.contains("@font-face"))
        #expect(localOnlyResult.css.contains("color: #223344"))
        #expect(localOnlyResult.styleCompatibility == EPUBStyleCompatibility(issues: [.fontUnavailable], usesReaderLayout: false))

        let selfCycleResult = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            #"@\69 mport "good.css"; p { color: #334455; }"#,
            sourcePath: "OPS/Styles/good.css",
            documentPath: "OPS/Text/ch1.xhtml",
            manifestByPath: manifest,
            destination: root
        )
        #expect(selfCycleResult.referencedFonts.isEmpty)
        #expect(selfCycleResult.css.contains("color: #334455"))
        #expect(selfCycleResult.styleCompatibility == EPUBStyleCompatibility(issues: [.localImportCycle], usesReaderLayout: false))

        let missingFontResult = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            #"@font-face { font-family: Missing; src: url(../Fonts/missing.ttf); } p { color: #445566; }"#,
            sourcePath: "OPS/Styles/good.css",
            documentPath: "OPS/Text/ch1.xhtml",
            manifestByPath: manifest,
            destination: root
        )
        #expect(missingFontResult.referencedFonts.isEmpty)
        #expect(!missingFontResult.css.contains("@font-face"))
        #expect(missingFontResult.css.contains("color: #445566"))
        #expect(missingFontResult.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing, .fontUnavailable], usesReaderLayout: false))

        let missingBgResult = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            #"p { background: url(../Images/unknown.png); color: #556677; }"#,
            sourcePath: "OPS/Styles/good.css",
            documentPath: "OPS/Text/ch1.xhtml",
            manifestByPath: manifest,
            destination: root
        )
        #expect(missingBgResult.referencedFonts.isEmpty)
        #expect(!missingBgResult.css.contains("unknown.png"))
        #expect(!missingBgResult.css.contains("background"))
        #expect(missingBgResult.css.contains("color: #556677"))
        #expect(missingBgResult.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing], usesReaderLayout: false))

        // 4. Inline style attributes and <link> attacks in sanitizeXHTML
        let badXHTMLPayloads: [String] = [
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="https://evil.invalid/a.css"/></head><body><p>T</p></body></html>"#,
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="//evil.invalid/a.css"/></head><body><p>T</p></body></html>"#,
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="../../../outside.css"/></head><body><p>T</p></body></html>"#,
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="../Fonts/valid.ttf"/></head><body><p>T</p></body></html>"#,
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><p style="background: \75 rl(https://evil.invalid/a.png);">T</p></body></html>"#,
            #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><p style="width: \65 xpression(1);">T</p></body></html>"#
        ]
        for xhtml in badXHTMLPayloads {
            #expect(throws: (any Error).self) {
                _ = try EPUBContentPolicy.sanitizeXHTML(
                    data: Data(xhtml.utf8),
                    path: "OPS/Text/ch1.xhtml",
                    manifestByPath: manifest,
                    spineSet: ["OPS/Text/ch1.xhtml"],
                    destination: root
                )
            }
        }

        // Missing optional <link> stylesheet and missing inline background image degrade safely with unchanged textNodes.
        let missingLinkXHTML = #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title><link rel="stylesheet" href="../Styles/missing.css"/></head><body><p>T</p></body></html>"#
        let missingLinkDoc = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(missingLinkXHTML.utf8),
            path: "OPS/Text/ch1.xhtml",
            manifestByPath: manifest,
            spineSet: ["OPS/Text/ch1.xhtml"],
            destination: root
        )
        #expect(missingLinkDoc.textNodes == ["T"])
        #expect(missingLinkDoc.referencedFonts.isEmpty)
        #expect(missingLinkDoc.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing], usesReaderLayout: false))
        #expect(!String(decoding: missingLinkDoc.xhtmlData, as: UTF8.self).contains("data-yj-style-fallback"))

        let missingInlineBgXHTML = #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><p style="background: url(../Images/unknown.png); color: #123456;">T</p></body></html>"#
        let missingInlineBgDoc = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(missingInlineBgXHTML.utf8),
            path: "OPS/Text/ch1.xhtml",
            manifestByPath: manifest,
            spineSet: ["OPS/Text/ch1.xhtml"],
            destination: root
        )
        let missingInlineText = String(decoding: missingInlineBgDoc.xhtmlData, as: UTF8.self)
        #expect(missingInlineBgDoc.textNodes == ["T"])
        #expect(missingInlineText.contains("color: #123456"))
        #expect(!missingInlineText.contains("unknown.png"))
        #expect(!missingInlineText.contains("data-yj-style-fallback"))
        #expect(missingInlineBgDoc.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing], usesReaderLayout: false))
        // 5. External CSS exceeding 1 MiB budget -> limitExceeded
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Styles"), withIntermediateDirectories: true)
        let bigCSS = Data(repeating: 0x20, count: EPUBAuthorStyles.maxExternalCSSBytes + 1)
        try bigCSS.write(to: root.appendingPathComponent("OPS/Styles/big.css"))
        var bigManifest = manifest
        bigManifest["OPS/Styles/big.css"] = "text/css"
        let bigXHTML = #"<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="../Styles/big.css"/></head><body><p>T</p></body></html>"#
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBContentPolicy.sanitizeXHTML(
                data: Data(bigXHTML.utf8),
                path: "OPS/Text/ch1.xhtml",
                manifestByPath: bigManifest,
                spineSet: ["OPS/Text/ch1.xhtml"],
                destination: root
            )
        }
    }

    @Test func authorStylesRejectsCorruptOversizedAndInvalidSFNTFontsAndDRM() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let validTTF = makeMinimalSFNT(flavor: .ttf)
        let validOTF = makeMinimalSFNT(flavor: .otf)

        // 1. Unsupported font formats & SFNT signature/MIME mismatches
        var woffHeader = validTTF
        woffHeader.replaceSubrange(0..<4, with: Data("wOFF".utf8))
        var woff2Header = validTTF
        woff2Header.replaceSubrange(0..<4, with: Data("wOF2".utf8))
        var ttcHeader = validTTF
        ttcHeader.replaceSubrange(0..<4, with: Data("ttcf".utf8))

        for badFormat in [woffHeader, woff2Header, ttcHeader] {
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBAuthorStyles.verifyFontData(badFormat, declaredMediaType: "font/ttf")
            }
        }
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBAuthorStyles.verifyFontData(validOTF, declaredMediaType: "font/ttf")
        }
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBAuthorStyles.verifyFontData(validTTF, declaredMediaType: "font/otf")
        }

        // 2. Single font > 8 MiB -> limitExceeded
        let oversizedFont = Data(repeating: 0, count: EPUBAuthorStyles.maxFontBytes + 1)
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBAuthorStyles.verifyFontData(oversizedFont, declaredMediaType: "font/ttf")
        }

        // 3. Corrupt SFNT headers and table boundary violations
        let malformedSFNTs: [Data] = [
            Data(),
            Data([0x00, 0x01, 0x00, 0x00]),
            Data("not-an-sfnt-font".utf8),
            // numTables = 0
            makeRawSFNT(sfntVersion: 0x00010000, tables: []),
            // numTables = 257 (exceeds directory bound)
            makeNumTablesOnlySFNT(numTables: 257),
            // Truncated directory
            Data(validTTF.prefix(20)),
            // Duplicate tag
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("head", 100, 54)
            ], bodySize: 200, patchHeadMagicAt: 44),
            // Table offset inside directory (< 12 + 2*16 = 44)
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 20, 54),
                ("glyf", 80, 16)
            ], bodySize: 200, patchHeadMagicAt: nil),
            // Table offset + length overflows data.count
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("glyf", 100, 500)
            ], bodySize: 120, patchHeadMagicAt: 44),
            // UInt32 integer overflow in offset + length
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("glyf", 0xFFFFFFF0, 0x40)
            ], bodySize: 120, patchHeadMagicAt: 44),
            // Zero-length table
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("glyf", 100, 0)
            ], bodySize: 120, patchHeadMagicAt: 44),
            // Overlapping tables
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("glyf", 80, 32)
            ], bodySize: 150, patchHeadMagicAt: 44),
            // Missing head table
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("glyf", 28, 32)
            ], bodySize: 100, patchHeadMagicAt: nil),
            // Short head table (< 54)
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 40),
                ("glyf", 84, 16)
            ], bodySize: 120, patchHeadMagicAt: 44),
            // Wrong head magicNumber (not 0x5F0F3CF5)
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("glyf", 100, 16)
            ], bodySize: 120, patchHeadMagicAt: nil),
            // TTF missing glyf
            makeRawSFNT(sfntVersion: 0x00010000, rawRecords: [
                ("head", 44, 54),
                ("name", 100, 16)
            ], bodySize: 120, patchHeadMagicAt: 44),
            // OTF missing CFF/CFF2
            makeRawSFNT(sfntVersion: 0x4F54544F, rawRecords: [
                ("head", 44, 54),
                ("glyf", 100, 16)
            ], bodySize: 120, patchHeadMagicAt: 44)
        ]
        for bad in malformedSFNTs {
            #expect(throws: EPUBError.corruptResource) {
                _ = try EPUBAuthorStyles.verifyFontData(bad, declaredMediaType: bad.starts(with: Data("OTTO".utf8)) ? "font/otf" : "font/ttf")
            }
        }

        // 4. Symlink font and missing font file on disk
        let fontDir = root.appendingPathComponent("symroot/OPS/Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fontDir, withIntermediateDirectories: true)
        let outsideFont = root.appendingPathComponent("outside.ttf")
        try validTTF.write(to: outsideFont)
        try FileManager.default.createSymbolicLink(at: fontDir.appendingPathComponent("link.ttf"), withDestinationURL: outsideFont)
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBAuthorStyles.verifyExtractedFont(at: "OPS/Fonts/link.ttf", under: root.appendingPathComponent("symroot"), declaredMediaType: "font/ttf")
        }
        #expect(throws: EPUBError.invalidPackage) {
            _ = try EPUBAuthorStyles.verifyExtractedFont(at: "OPS/Fonts/missing.ttf", under: root.appendingPathComponent("symroot"), declaredMediaType: "font/ttf")
        }

        // 5. Package-level total font budget > 32 MiB (5 x 7 MiB valid SFNT = 35 MiB) -> limitExceeded
        let sevenMiBFont = makeMinimalSFNT(flavor: .ttf, targetSize: 7 * 1024 * 1024)
        let totalBudgetURL = root.appendingPathComponent("over-total-fonts.epub")
        var chapters: [EPUBSyntheticChapter] = []
        var manifestItems: [String] = []
        var fontEntries: [(String, Data)] = []
        for i in 0..<5 {
            let xhtml = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>C\(i)</title>
            <style>@font-face { font-family: F\(i); src: url(Fonts/f\(i).ttf); } p { font-family: F\(i); }</style>
            </head><body><p id="h\(i)">Chapter \(i)</p></body></html>
            """
            chapters.append(EPUBSyntheticChapter(id: "c\(i)", path: "c\(i).xhtml", title: "C\(i)", headingID: "h\(i)", bodyXHTML: xhtml))
            manifestItems.append("<item id=\"f\(i)\" href=\"Fonts/f\(i).ttf\" media-type=\"font/ttf\"/>")
            fontEntries.append(("OPS/Fonts/f\(i).ttf", sevenMiBFont))
        }
        try EPUBTestSupport.writeEPUB3(
            at: totalBudgetURL,
            chapters: chapters,
            manifestExtra: manifestItems.joined(),
            extraEntries: fontEntries,
            compress: false
        )
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBPackageParser.parse(archiveURL: totalBudgetURL, destination: root.appendingPathComponent("over-total-dest", isDirectory: true))
        }

        // 6. Font obfuscation / encryption.xml and fixed-layout remain rejected
        let drmFontURL = root.appendingPathComponent("obfuscated-font.epub")
        try EPUBTestSupport.writeEPUB3(
            at: drmFontURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "c1",
                    path: "one.xhtml",
                    title: "One",
                    bodyXHTML: #"<html xmlns="http://www.w3.org/1999/xhtml"><head><style>@font-face { font-family: F; src: url(Fonts/f.ttf); }</style></head><body><p id="heading">Text</p></body></html>"#
                )
            ],
            manifestExtra: #"<item id="f" href="Fonts/f.ttf" media-type="font/ttf"/>"#,
            extraEntries: [
                ("OPS/Fonts/f.ttf", validTTF),
                ("META-INF/encryption.xml", Data("<encryption/>".utf8))
            ]
        )
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBPackageParser.parse(archiveURL: drmFontURL, destination: root.appendingPathComponent("drm-dest", isDirectory: true))
        }

        let fixedLayoutURL = root.appendingPathComponent("fixed-with-style.epub")
        try EPUBTestSupport.writeEPUB3(
            at: fixedLayoutURL,
            chapters: [
                EPUBSyntheticChapter(
                    id: "c1",
                    path: "one.xhtml",
                    title: "Fixed",
                    bodyXHTML: #"<html xmlns="http://www.w3.org/1999/xhtml"><head><style>p { color: #111; }</style></head><body><p id="heading">Text</p></body></html>"#
                )
            ],
            metadataExtra: #"<meta property="rendition:layout">pre-paginated</meta>"#
        )
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBPackageParser.parse(archiveURL: fixedLayoutURL, destination: root.appendingPathComponent("fixed-dest", isDirectory: true))
        }
    }

    // MARK: - Synthetic Helpers

    private enum FontFlavor {
        case ttf
        case otf
    }

    private func makeMinimalSFNT(flavor: FontFlavor, targetSize: Int? = nil) -> Data {
        var head = Data(repeating: 0, count: 54)
        // head.magicNumber at offset 12 = 0x5F0F3CF5
        writeUInt32BE(0x5F0F3CF5, into: &head, at: 12)
        let hhea = Data(repeating: 0, count: 36)
        let maxp = Data(repeating: 0, count: 6)
        let name = Data(repeating: 0, count: 8)
        let outlineSize = max(16, (targetSize ?? 0) - 256)
        let outline = Data(repeating: 0x01, count: outlineSize)

        var tables: [(String, Data)] = [
            ("head", head),
            ("hhea", hhea),
            ("maxp", maxp),
            ("name", name)
        ]
        let version: UInt32
        switch flavor {
        case .ttf:
            version = 0x00010000
            tables.append(("loca", Data(repeating: 0, count: 4)))
            tables.append(("glyf", outline))
        case .otf:
            version = 0x4F54544F
            tables.append(("CFF ", outline))
        }
        tables.sort { $0.0 < $1.0 }

        let numTables = tables.count
        let headerSize = 12 + numTables * 16
        var out = Data()
        appendUInt32BE(&out, version)
        appendUInt16BE(&out, UInt16(numTables))
        var maxPow2 = 1
        var entrySelector: UInt16 = 0
        while maxPow2 * 2 <= numTables {
            maxPow2 *= 2
            entrySelector += 1
        }
        let searchRange = UInt16(maxPow2 * 16)
        let rangeShift = UInt16(numTables * 16) - searchRange
        appendUInt16BE(&out, searchRange)
        appendUInt16BE(&out, entrySelector)
        appendUInt16BE(&out, rangeShift)

        var offset = headerSize
        var bodies = Data()
        for (tag, body) in tables {
            out.append(contentsOf: Array(tag.utf8))
            appendUInt32BE(&out, 0) // checksum
            appendUInt32BE(&out, UInt32(offset))
            appendUInt32BE(&out, UInt32(body.count))
            bodies.append(body)
            let pad = (4 - (body.count % 4)) % 4
            if pad > 0 {
                bodies.append(Data(repeating: 0, count: pad))
            }
            offset += body.count + pad
        }
        out.append(bodies)
        return out
    }

    private func makeNumTablesOnlySFNT(numTables: UInt16) -> Data {
        var out = Data()
        appendUInt32BE(&out, 0x00010000)
        appendUInt16BE(&out, numTables)
        appendUInt16BE(&out, 16)
        appendUInt16BE(&out, 0)
        appendUInt16BE(&out, 0)
        out.append(Data(repeating: 0, count: 256))
        return out
    }

    private func makeRawSFNT(sfntVersion: UInt32, tables: [(String, Data)]) -> Data {
        var out = Data()
        appendUInt32BE(&out, sfntVersion)
        appendUInt16BE(&out, UInt16(tables.count))
        appendUInt16BE(&out, 0)
        appendUInt16BE(&out, 0)
        appendUInt16BE(&out, 0)
        return out
    }

    private func makeRawSFNT(
        sfntVersion: UInt32,
        rawRecords: [(tag: String, offset: UInt32, length: UInt32)],
        bodySize: Int,
        patchHeadMagicAt: Int?
    ) -> Data {
        var out = Data(repeating: 0, count: max(12 + rawRecords.count * 16, bodySize))
        writeUInt32BE(sfntVersion, into: &out, at: 0)
        writeUInt16BE(UInt16(rawRecords.count), into: &out, at: 4)
        for (idx, rec) in rawRecords.enumerated() {
            let base = 12 + idx * 16
            let tagBytes = Array(rec.tag.utf8)
            for b in 0..<4 {
                out[base + b] = tagBytes[b]
            }
            writeUInt32BE(rec.offset, into: &out, at: base + 8)
            writeUInt32BE(rec.length, into: &out, at: base + 12)
        }
        if let headOffset = patchHeadMagicAt, headOffset + 16 <= out.count {
            writeUInt32BE(0x5F0F3CF5, into: &out, at: headOffset + 12)
        }
        return out
    }

    private func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private func extractAuthorStyleFromXHTML(_ xhtmlData: Data) throws -> String {
        final class StyleExtractor: NSObject, XMLParserDelegate {
            var capturing = false
            var captured: String?
            var current = ""

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                // Check the parsed attribute name, not a substring of the trusted style marker.
                #expect(attributeDict["style"] == nil)
                if elementName.lowercased() == "style", attributeDict["data-yj-author-style"] == "true" {
                    capturing = true
                    current = ""
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if capturing {
                    current.append(string)
                }
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                if capturing, elementName.lowercased() == "style" {
                    capturing = false
                    captured = current
                }
            }
        }

        let parser = XMLParser(data: xhtmlData)
        let extractor = StyleExtractor()
        parser.delegate = extractor
        #expect(parser.parse())
        return try #require(extractor.captured)
    }
}
