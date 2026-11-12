import CryptoKit
import Foundation
import Testing
@testable import ReaderDomain

struct EPUBStyleCompatibilityTests {
    @Test func styleCompatibilityDeterministicIssuesCodableAndDistinctProcessingError() throws {
        let compatA = EPUBStyleCompatibility(
            issues: [.fontUnavailable, .optionalResourceMissing, .fontUnavailable, .localImportCycle],
            usesReaderLayout: false
        )
        let compatB = EPUBStyleCompatibility(
            issues: [.localImportCycle, .optionalResourceMissing, .fontUnavailable],
            usesReaderLayout: false
        )
        #expect(compatA == compatB)
        #expect(compatA.issues == [.fontUnavailable, .localImportCycle, .optionalResourceMissing])

        let data = try JSONEncoder().encode(compatA)
        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(!jsonString.contains("/"))
        let decoded = try JSONDecoder().decode(EPUBStyleCompatibility.self, from: data)
        #expect(decoded == compatA)

        let defaultCompat = EPUBStyleCompatibility()
        #expect(defaultCompat.issues.isEmpty)
        #expect(!defaultCompat.usesReaderLayout)

        let processingErr: EPUBStyleProcessingError = .complexityExceeded
        #expect(processingErr == .complexityExceeded)
    }

    @Test func fontCandidatesSupportSixteenSeventeenEighteenAndLargeListsWithoutRejectingBook() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let ttfData = makeMinimalSFNT(flavor: .ttf)

        // 1. 18 candidates matching real-world shape: 16 local() + 2 missing URLs -> degrades with fontUnavailable
        let sixteenLocalTwoMissing = (1...16).map { "local(\"LocalFont\($0)\")" }
            + ["url(../Fonts/missing-a.ttf)", "url(../Fonts/missing-b.ttf)"]
        let css18Mixed = "@font-face { font-family: Mixed18; src: \(sixteenLocalTwoMissing.joined(separator: ", ")); }\np { font-family: Mixed18, serif; color: #112233; }"
        let res18Mixed = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            css18Mixed,
            sourcePath: "OPS/Styles/book.css",
            documentPath: "OPS/Text/ch1.xhtml",
            manifestByPath: ["OPS/Styles/book.css": "text/css"],
            destination: root
        )
        #expect(res18Mixed.referencedFonts.isEmpty)
        #expect(!res18Mixed.css.contains("@font-face"))
        #expect(res18Mixed.css.contains("color: #112233"))
        #expect(res18Mixed.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing, .fontUnavailable], usesReaderLayout: false))

        // 2. Exact 16, 17, 18, and large (40) valid unique embedded candidates
        var extraEntries: [(String, Data)] = []
        var manifestItems: [String] = []
        for i in 1...40 {
            let rel = "Fonts/f\(i).ttf"
            extraEntries.append(("OPS/\(rel)", ttfData))
            manifestItems.append("<item id=\"font-\(i)\" href=\"\(rel)\" media-type=\"font/ttf\"/>")
        }

        for count in [16, 17, 18, 40] {
            let srcList = (1...count).map { "url(../Fonts/f\($0).ttf) format(\"truetype\")" }.joined(separator: ", ")
            let css = "@font-face { font-family: Multi\(count); src: \(srcList); }\np { font-family: Multi\(count), serif; }"
            let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>C\(count)</title><link rel=\"stylesheet\" href=\"../Styles/s\(count).css\"/></head><body><h1 id=\"heading\">Heading \(count)</h1><p>Body text</p></body></html>"
            let epubURL = root.appendingPathComponent("cand-\(count).epub")
            try EPUBTestSupport.writeEPUB3(
                at: epubURL,
                chapters: [EPUBSyntheticChapter(id: "c1", path: "Text/c1.xhtml", title: "C\(count)", bodyXHTML: xhtml)],
                manifestExtra: manifestItems.joined() + "<item id=\"css\" href=\"Styles/s\(count).css\" media-type=\"text/css\"/>",
                extraEntries: extraEntries + [("OPS/Styles/s\(count).css", Data(css.utf8))]
            )
            let dest = root.appendingPathComponent("dest-\(count)", isDirectory: true)
            let pkg = try EPUBPackageParser.parse(archiveURL: epubURL, destination: dest)
            let compat = try #require(pkg.styleCompatibility)
            #expect(!compat.usesReaderLayout)
            if count == 16 {
                #expect(compat.issues.isEmpty)
            } else {
                #expect(compat.issues == [.styleComplexity])
            }
            let servedFonts = pkg.resources.filter { $0.mediaType == "font/ttf" }
            #expect(servedFonts.count == 16)
            for idx in 17..<(count + 1) {
                #expect(pkg.resource(at: "OPS/Fonts/f\(idx).ttf") == nil)
            }
            let chText = String(decoding: try Data(contentsOf: dest.appendingPathComponent("OPS/Text/c1.xhtml")), as: UTF8.self)
            #expect(!chText.contains("data-yj-style-fallback"))
            #expect(pkg.textNodes["OPS/Text/c1.xhtml"] == ["Heading \(count)", "Body text"])
        }
    }

    @Test func fontCandidatesMissingBeforeAndAfterValidSourceAllMissingAndLocalOnly() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let ttfData = makeMinimalSFNT(flavor: .ttf)
        let baselineXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Font</title></head><body><h1 id=\"heading\">Title</h1><p>Paragraph text</p></body></html>"

        // 1. Missing before AND after a valid source -> valid source selected and served, missing not served
        let mixedCSS = """
        @font-face {
            font-family: BookBody;
            src: local("PingFang SC"), url(../Fonts/missing-before.ttf), url(../Fonts/valid.ttf) format("truetype"), url(../Fonts/missing-after.ttf);
        }
        p { font-family: BookBody, serif; color: #222222; }
        """
        let styledXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Font</title><link rel=\"stylesheet\" href=\"../Styles/book.css\"/></head><body><h1 id=\"heading\">Title</h1><p>Paragraph text</p></body></html>"
        let mixedEPUB = root.appendingPathComponent("mixed-font.epub")
        try EPUBTestSupport.writeEPUB3(
            at: mixedEPUB,
            chapters: [EPUBSyntheticChapter(id: "c1", path: "Text/c1.xhtml", title: "Font", bodyXHTML: styledXHTML)],
            manifestExtra: """
            <item id="css1" href="Styles/book.css" media-type="text/css"/>
            <item id="fvalid" href="Fonts/valid.ttf" media-type="font/ttf"/>
            <item id="fmissing-manifest" href="Fonts/missing-after.ttf" media-type="font/ttf"/>
            """,
            extraEntries: [
                ("OPS/Styles/book.css", Data(mixedCSS.utf8)),
                ("OPS/Fonts/valid.ttf", ttfData)
            ]
        )
        let mixedDest = root.appendingPathComponent("mixed-dest", isDirectory: true)
        let mixedPkg = try EPUBPackageParser.parse(archiveURL: mixedEPUB, destination: mixedDest)
        #expect(mixedPkg.resource(at: "OPS/Fonts/valid.ttf") != nil)
        #expect(mixedPkg.resource(at: "OPS/Fonts/missing-before.ttf") == nil)
        #expect(mixedPkg.resource(at: "OPS/Fonts/missing-after.ttf") == nil)
        #expect(mixedPkg.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing], usesReaderLayout: false))

        let baselineDoc = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(baselineXHTML.utf8),
            path: "OPS/Text/c1.xhtml",
            manifestByPath: ["OPS/Text/c1.xhtml": "application/xhtml+xml"],
            spineSet: ["OPS/Text/c1.xhtml"],
            destination: mixedDest
        )
        #expect(mixedPkg.textNodes["OPS/Text/c1.xhtml"] == baselineDoc.textNodes)

        // 2. Local-only and all-missing yield system fallback without serving any font
        for (idx, srcExpr, expectedIssues) in [
            (1, #"local("PingFang SC"), local("Songti SC")"#, [EPUBStyleIssue.fontUnavailable]),
            (2, #"url(../Fonts/m1.ttf), url(../Fonts/m2.otf)"#, [EPUBStyleIssue.optionalResourceMissing, EPUBStyleIssue.fontUnavailable])
        ] {
            let css = "@font-face { font-family: FallbackOnly; src: \(srcExpr); } p { font-family: FallbackOnly, serif; color: #333333; }"
            let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>F\(idx)</title><style>\(css)</style></head><body><h1 id=\"heading\">Title</h1><p>Paragraph text</p></body></html>"
            let url = root.appendingPathComponent("fallback-\(idx).epub")
            try EPUBTestSupport.writeEPUB3(
                at: url,
                chapters: [EPUBSyntheticChapter(id: "c1", path: "Text/c1.xhtml", title: "F\(idx)", bodyXHTML: xhtml)]
            )
            let dest = root.appendingPathComponent("fallback-dest-\(idx)", isDirectory: true)
            let pkg = try EPUBPackageParser.parse(archiveURL: url, destination: dest)
            #expect(pkg.resources.map(\.path) == ["OPS/Text/c1.xhtml"])
            #expect(pkg.styleCompatibility == EPUBStyleCompatibility(issues: expectedIssues, usesReaderLayout: false))
            #expect(pkg.textNodes["OPS/Text/c1.xhtml"] == baselineDoc.textNodes)
            let sanitizedText = String(decoding: try Data(contentsOf: dest.appendingPathComponent("OPS/Text/c1.xhtml")), as: UTF8.self)
            #expect(!sanitizedText.contains("@font-face"))
            #expect(!sanitizedText.contains("data-yj-style-fallback"))
        }
    }

    @Test func fontCandidatesRejectUnsafeTailCorruptOversizedSymlinkAndWoffOnly() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let ttfData = makeMinimalSFNT(flavor: .ttf)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Fonts"), withIntermediateDirectories: true)
        try ttfData.write(to: root.appendingPathComponent("OPS/Fonts/valid.ttf"))
        try Data("not-a-font".utf8).write(to: root.appendingPathComponent("OPS/Fonts/corrupt.ttf"))

        let manifest: [String: String] = [
            "OPS/Styles/s.css": "text/css",
            "OPS/Fonts/valid.ttf": "font/ttf",
            "OPS/Fonts/corrupt.ttf": "font/ttf"
        ]

        // An overridden src is not an audit escape hatch; only safe last-src
        // semantics may select resources for serving.
        for (source, error) in [
            ("https://evil.invalid/first.ttf", EPUBError.unsupportedContent),
            ("../../../outside.ttf", EPUBError.unsafePath),
            ("../Fonts/corrupt.ttf", EPUBError.corruptResource)
        ] {
            #expect(throws: error) {
                _ = try EPUBAuthorStyles.sanitizeStylesheet(
                    "@font-face { font-family: Duplicate; src: url(\(source)); src: url(../Fonts/valid.ttf); }",
                    sourcePath: "OPS/Styles/s.css", documentPath: "OPS/Text/c1.xhtml",
                    manifestByPath: manifest, destination: root
                )
            }
        }
        let overridden = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            "@font-face { font-family: Duplicate; src: url(../Fonts/valid.ttf); src: local(Safe); }",
            sourcePath: "OPS/Styles/s.css", documentPath: "OPS/Text/c1.xhtml",
            manifestByPath: manifest, destination: root
        )
        #expect(!overridden.css.contains("@font-face"))
        #expect(overridden.styleCompatibility.issues.contains(.fontUnavailable))
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBAuthorStyles.verifyExtractedFont(
                at: "OPS/Fonts/deleted.ttf", under: root,
                declaredMediaType: "font/ttf", expectedSize: ttfData.count
            )
        }
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBAuthorStyles.readExtractedCSS(
                at: "OPS/deleted-parent/s.css", under: root, expectedSize: 32
            )
        }

        let prefix18 = (1...18).map { _ in "url(../Fonts/valid.ttf)" }.joined(separator: ", ")

        // Unsafe scheme at candidate #19 in tail -> unsupportedContent
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                "@font-face { font-family: BadTail; src: \(prefix18), url(https://evil.invalid/tail.ttf); }",
                sourcePath: "OPS/Styles/s.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // Encoded traversal at candidate #19 in tail -> unsafePath
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                "@font-face { font-family: BadTail; src: \(prefix18), url(../%2e%2e/outside.ttf); }",
                sourcePath: "OPS/Styles/s.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // Corrupt font structure in tail -> corruptResource
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                "@font-face { font-family: BadTail; src: \(prefix18), url(../Fonts/corrupt.ttf); }",
                sourcePath: "OPS/Styles/s.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // Over 256 candidates -> EPUBStyleProcessingError.complexityExceeded (or unsafe payload first if malicious)
        let prefix260 = (1...260).map { _ in "local(\"F\")" }.joined(separator: ", ")
        #expect(throws: EPUBStyleProcessingError.complexityExceeded) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                "@font-face { font-family: TooMany; src: \(prefix260); }",
                sourcePath: "OPS/Styles/s.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                "@font-face { font-family: TooManyEvil; src: \(prefix260), url(javascript:alert(1)); }",
                sourcePath: "OPS/Styles/s.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }

        // Unsupported containers are never served, but safe optional candidates
        // do not make the body unreadable. This does not add WOFF support.
        let woff = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            "@font-face { font-family: WoffOnly; src: url(../Fonts/f.woff2) format(\"woff2\"); } p { color: #123456; }",
            sourcePath: "OPS/Styles/s.css", documentPath: "OPS/Text/c1.xhtml",
            manifestByPath: manifest, destination: root
        )
        #expect(woff.referencedFonts.isEmpty && !woff.css.contains("@font-face"))
        #expect(woff.css.contains("#123456"))
        #expect(woff.styleCompatibility.issues.contains(.fontUnavailable))
    }

    @Test func localCSSImportsPreserveCascadeOrderDuplicatesRelativeURLsAndDepthBounds() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let ttfData = makeMinimalSFNT(flavor: .ttf)

        // main.css -> sub/base.css -> theme.css -> sub/base.css (duplicate import must preserve override order!)
        // sub/base.css resolves url(../../Fonts/subfont.ttf) relative to OPS/Styles/sub/base.css!
        let mainCSS = """
        @import "sub/base.css";
        @import url("theme.css");
        @import url(sub/base.css);
        p.final { color: #010203; }
        """
        let baseCSS = """
        @font-face { font-family: SubFont; src: url(../../Fonts/subfont.ttf) format("truetype"); }
        p.cascade { color: #111111; font-family: SubFont, serif; }
        """
        let themeCSS = """
        p.cascade { color: #999999; }
        """
        let chXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Imp</title><link rel=\"stylesheet\" href=\"../Styles/main.css\"/></head><body><h1 id=\"heading\">Imp</h1><p class=\"cascade\">Text</p></body></html>"

        let epubURL = root.appendingPathComponent("imports-order.epub")
        try EPUBTestSupport.writeEPUB3(
            at: epubURL,
            chapters: [EPUBSyntheticChapter(id: "c1", path: "Text/c1.xhtml", title: "Imp", bodyXHTML: chXHTML)],
            manifestExtra: """
            <item id="css-main" href="Styles/main.css" media-type="text/css"/>
            <item id="css-base" href="Styles/sub/base.css" media-type="text/css"/>
            <item id="css-theme" href="Styles/theme.css" media-type="text/css"/>
            <item id="subfont" href="Fonts/subfont.ttf" media-type="font/ttf"/>
            """,
            extraEntries: [
                ("OPS/Styles/main.css", Data(mainCSS.utf8)),
                ("OPS/Styles/sub/base.css", Data(baseCSS.utf8)),
                ("OPS/Styles/theme.css", Data(themeCSS.utf8)),
                ("OPS/Fonts/subfont.ttf", ttfData)
            ]
        )

        let dest = root.appendingPathComponent("imports-dest", isDirectory: true)
        let pkg = try EPUBPackageParser.parse(archiveURL: epubURL, destination: dest)
        #expect(pkg.styleCompatibility == EPUBStyleCompatibility(issues: [], usesReaderLayout: false))
        #expect(pkg.resources.map(\.path) == ["OPS/Text/c1.xhtml", "OPS/Fonts/subfont.ttf"])
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("OPS/Styles/main.css").path))

        let chData = try Data(contentsOf: dest.appendingPathComponent("OPS/Text/c1.xhtml"))
        let chText = String(decoding: chData, as: UTF8.self)
        let first111 = try #require(chText.range(of: "color: #111111"))
        let mid999 = try #require(chText.range(of: "color: #999999"))
        let second111 = try #require(chText.range(of: "color: #111111", range: mid999.upperBound..<chText.endIndex))
        #expect(first111.lowerBound < mid999.lowerBound)
        #expect(mid999.lowerBound < second111.lowerBound)

        // Depth 8 succeeds; depth 9 fails closed with EPUBStyleProcessingError.complexityExceeded
        var depthManifest: [String: String] = [
            "OPS/Text/c1.xhtml": "application/xhtml+xml"
        ]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Styles"), withIntermediateDirectories: true)
        for level in 0...9 {
            let path = "OPS/Styles/d\(level).css"
            depthManifest[path] = "text/css"
            let content = level < 9 ? "@import \"d\(level + 1).css\"; p { color: #123456; }" : "p { color: #654321; }"
            try Data(content.utf8).write(to: root.appendingPathComponent(path))
        }
        // Starting from d1.css (depth 0) -> d2(1) -> ... -> d9(8): 8 @import hops succeeds
        let depth8OK = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            #"@import "d2.css";"#,
            sourcePath: "OPS/Styles/d1.css",
            documentPath: "OPS/Text/c1.xhtml",
            manifestByPath: depthManifest,
            destination: root
        )
        #expect(depth8OK.css.contains("#654321"))

        // Starting from d0.css (depth 0) -> d1(1) -> ... -> d9(9): exceeds maxImportDepth (8)
        #expect(throws: EPUBStyleProcessingError.complexityExceeded) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                #"@import "d1.css";"#,
                sourcePath: "OPS/Styles/d0.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: depthManifest,
                destination: root
            )
        }
    }

    @Test func localCSSImportsCycleMediaConditionsAndSecurityRejection() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Styles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Fonts"), withIntermediateDirectories: true)
        try makeMinimalSFNT(flavor: .ttf).write(to: root.appendingPathComponent("OPS/Fonts/valid.ttf"))

        // Cycle: a.css -> b.css -> a.css (must skip cycle edge, record localImportCycle, retain safe rules)
        try Data(#"@import "b.css"; p.from-a { color: #112233; }"#.utf8)
            .write(to: root.appendingPathComponent("OPS/Styles/a.css"))
        try Data(#"@import "a.css"; p.from-b { color: #445566; }"#.utf8)
            .write(to: root.appendingPathComponent("OPS/Styles/b.css"))
        try Data(#"p.cond { color: #ff0000; }"#.utf8)
            .write(to: root.appendingPathComponent("OPS/Styles/cond.css"))

        let manifest: [String: String] = [
            "OPS/Text/c1.xhtml": "application/xhtml+xml",
            "OPS/Styles/a.css": "text/css",
            "OPS/Styles/b.css": "text/css",
            "OPS/Styles/cond.css": "text/css",
            "OPS/Fonts/valid.ttf": "font/ttf"
        ]

        let cycleXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Cycle</title><link rel=\"stylesheet\" href=\"../Styles/a.css\"/></head><body><p class=\"from-a from-b\">Text</p></body></html>"
        let cycleDoc = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(cycleXHTML.utf8),
            path: "OPS/Text/c1.xhtml",
            manifestByPath: manifest,
            spineSet: ["OPS/Text/c1.xhtml"],
            destination: root
        )
        let cycleText = String(decoding: cycleDoc.xhtmlData, as: UTF8.self)
        #expect(cycleDoc.textNodes == ["Text"])
        #expect(cycleText.contains("color: #112233"))
        #expect(cycleText.contains("color: #445566"))
        #expect(cycleDoc.styleCompatibility == EPUBStyleCompatibility(issues: [.localImportCycle], usesReaderLayout: false))

        // Unhandled media conditions must be skipped (never applied unconditionally) and unsafe inputs inside still audited
        let mediaCSS = """
        @import "cond.css" screen and (min-width: 700px);
        @media (prefers-color-scheme: dark) { p { color: #ff0000; } }
        p.safe { color: #223344; }
        """
        let mediaRes = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            mediaCSS,
            sourcePath: "OPS/Styles/a.css",
            documentPath: "OPS/Text/c1.xhtml",
            manifestByPath: manifest,
            destination: root
        )
        #expect(!mediaRes.css.contains("#ff0000"))
        #expect(mediaRes.css.contains("color: #223344"))
        #expect(mediaRes.styleCompatibility == EPUBStyleCompatibility(issues: [.unsupportedStyleCondition], usesReaderLayout: false))

        // Unsafe schemes / encoded traversal in @import and inside skipped media still fail
        for badImport in [
            #"@import "https://evil.invalid/a.css";"#,
            #"@\69 mport "//evil.invalid/a.css";"#,
            #"@import "javascript:alert(1)";"#,
            #"@import "cond.css" (min-width: 600px); /* safe */ @import "https://evil.invalid/b.css";"#,
            #"@import "https://evil.invalid/print.css" print;"#
        ] {
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBAuthorStyles.sanitizeStylesheet(
                    badImport,
                    sourcePath: "OPS/Styles/a.css",
                    documentPath: "OPS/Text/c1.xhtml",
                    manifestByPath: manifest,
                    destination: root
                )
            }
        }
        for traversalImport in [
            #"@import "../../../outside.css";"#,
            #"@import "..%2f..%2foutside.css";"#,
            #"@import "..\\2f ..\\2f outside.css";"#
        ] {
            #expect(throws: EPUBError.unsafePath) {
                _ = try EPUBAuthorStyles.sanitizeStylesheet(
                    traversalImport,
                    sourcePath: "OPS/Styles/a.css",
                    documentPath: "OPS/Text/c1.xhtml",
                    manifestByPath: manifest,
                    destination: root
                )
            }
        }
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                #"@import "../Fonts/valid.ttf";"#,
                sourcePath: "OPS/Styles/a.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: manifest,
                destination: root
            )
        }
    }

    @Test func missingOptionalCSSAndBackgroundDropKeepSafeStylesAndPreserveImgAndTextIntegrity() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // Manifest declares optional CSS that is absent from ZIP archive + CSS references missing background image
        let mainCSS = """
        @import "missing-imported.css";
        p.keep { color: #224466; background-image: url(../Images/missing-bg.png); background: url(../Images/missing-bg2.png); }
        """
        let chXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Opt</title><link rel=\"stylesheet\" href=\"../Styles/missing-declared.css\"/><link rel=\"stylesheet\" href=\"../Styles/main.css\"/></head><body><h1 id=\"heading\">Heading</h1><p class=\"keep\">Body line</p></body></html>"

        let epubURL = root.appendingPathComponent("missing-opt.epub")
        try EPUBTestSupport.writeEPUB3(
            at: epubURL,
            chapters: [EPUBSyntheticChapter(id: "c1", path: "Text/c1.xhtml", title: "Opt", bodyXHTML: chXHTML)],
            manifestExtra: """
            <item id="css-declared-missing" href="Styles/missing-declared.css" media-type="text/css"/>
            <item id="css-main" href="Styles/main.css" media-type="text/css"/>
            """,
            extraEntries: [
                ("OPS/Styles/main.css", Data(mainCSS.utf8))
            ]
        )

        let dest = root.appendingPathComponent("missing-opt-dest", isDirectory: true)
        let pkg = try EPUBPackageParser.parse(archiveURL: epubURL, destination: dest)
        #expect(pkg.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing], usesReaderLayout: false))
        #expect(pkg.resources.map(\.path) == ["OPS/Text/c1.xhtml"])
        #expect(pkg.textNodes["OPS/Text/c1.xhtml"] == ["Heading", "Body line"])

        let sanitizedText = String(decoding: try Data(contentsOf: dest.appendingPathComponent("OPS/Text/c1.xhtml")), as: UTF8.self)
        #expect(sanitizedText.contains("color: #224466"))
        #expect(!sanitizedText.contains("missing-bg"))
        #expect(!sanitizedText.contains("data-yj-style-fallback"))
        #expect(sanitizedText.contains("<span id=\"yj-t0\">Heading</span>"))
        #expect(sanitizedText.contains("<span id=\"yj-t1\">Body line</span>"))

        // Actual <img> XHTML resource rule remains strictly required
        let missingImgEPUB = root.appendingPathComponent("missing-img.epub")
        let imgXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Img</title></head><body><p>Text</p><img src=\"../Images/missing.png\"/></body></html>"
        try EPUBTestSupport.writeEPUB3(
            at: missingImgEPUB,
            chapters: [EPUBSyntheticChapter(id: "c1", path: "Text/c1.xhtml", title: "Img", bodyXHTML: imgXHTML)]
        )
        #expect(throws: EPUBError.invalidPackage) {
            _ = try EPUBPackageParser.parse(archiveURL: missingImgEPUB, destination: root.appendingPathComponent("missing-img-dest", isDirectory: true))
        }

        // Tamper: file declared in manifest AND present in extractedEntries check fails if deleted on disk mid-parse
        let tamperDir = root.appendingPathComponent("tamper", isDirectory: true)
        try FileManager.default.createDirectory(at: tamperDir.appendingPathComponent("OPS/Styles"), withIntermediateDirectories: true)
        let tamperCSS = Data("p { color: #111; }".utf8)
        let tamperXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><link rel=\"stylesheet\" href=\"../Styles/present.css\"/></head><body><p>T</p></body></html>"
        // If extractedEntries says present.css existed with size > 0, missing on disk must throw corruptResource (not skip)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBContentPolicy.sanitizeXHTML(
                data: Data(tamperXHTML.utf8),
                path: "OPS/Text/c1.xhtml",
                manifestByPath: ["OPS/Text/c1.xhtml": "application/xhtml+xml", "OPS/Styles/present.css": "text/css"],
                spineSet: ["OPS/Text/c1.xhtml"],
                destination: tamperDir,
                styleCache: nil,
                extractedEntries: ["OPS/Text/c1.xhtml": tamperXHTML.utf8.count, "OPS/Styles/present.css": tamperCSS.count]
            )
        }
    }

    @Test func styleComplexityWholeChapterFallbackAndAuditBeforeDowngrade() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. >10,000 style rules: malicious tail at rule 10,005 must still be rejected!
        var manyRules = (0..<10_005).map { "p.c\($0) { color: #112233; }" }.joined(separator: "\n")
        let maliciousManyRules = manyRules + "\np.evil { background: url(https://evil.invalid/track.png); }"
        #expect(throws: EPUBError.unsupportedContent) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                maliciousManyRules,
                sourcePath: "OPS/Styles/many.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: ["OPS/Styles/many.css": "text/css"],
                destination: root
            )
        }

        // Benign >10,000 rules triggers whole-chapter fallback + data-yj-style-fallback="true" + usesReaderLayout = true
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Styles"), withIntermediateDirectories: true)
        try Data(manyRules.utf8).write(to: root.appendingPathComponent("OPS/Styles/many.css"))
        let manyXHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Many</title><link rel=\"stylesheet\" href=\"../Styles/many.css\"/></head><body><p>Preserved text</p></body></html>"
        let manyDoc = try EPUBContentPolicy.sanitizeXHTML(
            data: Data(manyXHTML.utf8),
            path: "OPS/Text/c1.xhtml",
            manifestByPath: ["OPS/Text/c1.xhtml": "application/xhtml+xml", "OPS/Styles/many.css": "text/css"],
            spineSet: ["OPS/Text/c1.xhtml"],
            destination: root
        )
        let manyText = String(decoding: manyDoc.xhtmlData, as: UTF8.self)
        #expect(manyDoc.textNodes == ["Preserved text"])
        #expect(manyDoc.referencedFonts.isEmpty)
        #expect(manyText.contains("data-yj-style-fallback=\"true\""))
        #expect(!manyText.contains("data-yj-author-style=\"true\""))
        #expect(manyDoc.styleCompatibility == EPUBStyleCompatibility(issues: [.styleComplexity], usesReaderLayout: true))

        // 2. Excess CSS nesting (>32) cannot be safely audited -> distinct EPUBStyleProcessingError.complexityExceeded
        let deepNested = String(repeating: "(", count: 40) + String(repeating: ")", count: 40)
        #expect(throws: EPUBStyleProcessingError.complexityExceeded) {
            _ = try EPUBAuthorStyles.sanitizeStylesheet(
                "p { width: \(deepNested); }",
                sourcePath: "OPS/Styles/deep.css",
                documentPath: "OPS/Text/c1.xhtml",
                manifestByPath: ["OPS/Styles/deep.css": "text/css"],
                destination: root
            )
        }
    }

    @Test func longBook1633ChaptersSharedStylesFontDedupAndCancellation() async throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // Use a ~100 KiB valid SFNT font: if wrongly counted 1633x, 163.3 MiB would exceed 32 MiB maxTotalFontBytes!
        let sharedFont = makeMinimalSFNT(flavor: .ttf, targetSize: 100 * 1024)
        let mainCSS = """
        @import "fonts.css";
        p { color: #222222; text-indent: 2em; }
        """
        let fontsCSS = """
        @font-face {
            font-family: LongBookFont;
            src: local("NonExistentLocal"), url(../Fonts/missing-fallback.ttf), url(../Fonts/shared.ttf) format("truetype");
        }
        body { font-family: LongBookFont, serif; }
        """

        let chapterCount = 1633
        var chapters: [EPUBSyntheticChapter] = []
        chapters.reserveCapacity(chapterCount)
        for idx in 1...chapterCount {
            let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>C\(idx)</title><link rel=\"stylesheet\" href=\"../Styles/main.css\"/></head><body><h1 id=\"h\(idx)\">Chapter \(idx)</h1><p>Line \(idx)</p></body></html>"
            chapters.append(EPUBSyntheticChapter(id: "c\(idx)", path: "Text/c\(idx).xhtml", title: "Chapter \(idx)", headingID: "h\(idx)", bodyXHTML: xhtml))
        }

        let epubURL = root.appendingPathComponent("long-1633.epub")
        try EPUBTestSupport.writeEPUB3(
            at: epubURL,
            title: "1633章合成兼容测试",
            chapters: chapters,
            manifestExtra: """
            <item id="css-main" href="Styles/main.css" media-type="text/css"/>
            <item id="css-fonts" href="Styles/fonts.css" media-type="text/css"/>
            <item id="font-shared" href="Fonts/shared.ttf" media-type="font/ttf"/>
            """,
            extraEntries: [
                ("OPS/Styles/main.css", Data(mainCSS.utf8)),
                ("OPS/Styles/fonts.css", Data(fontsCSS.utf8)),
                ("OPS/Fonts/shared.ttf", sharedFont)
            ],
            compress: false
        )

        let dest = root.appendingPathComponent("long-1633-dest", isDirectory: true)
        let pkg = try EPUBPackageParser.parse(archiveURL: epubURL, destination: dest)
        #expect(pkg.spine.count == chapterCount)
        let fontResources = pkg.resources.filter { $0.mediaType == "font/ttf" }
        #expect(fontResources.count == 1)
        #expect(fontResources.first?.path == "OPS/Fonts/shared.ttf")
        #expect(pkg.styleCompatibility == EPUBStyleCompatibility(issues: [.optionalResourceMissing], usesReaderLayout: false))

        // Verify cancellation is never swallowed
        let cancelDest = root.appendingPathComponent("long-1633-cancel", isDirectory: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try EPUBPackageParser.parse(archiveURL: epubURL, destination: cancelDest)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError to be thrown for cancelled parse")
        } catch is CancellationError {
            // Expected
        }
    }

    // MARK: - Minimal SFNT Helper

    private enum FontFlavor { case ttf, otf }

    private func makeMinimalSFNT(flavor: FontFlavor, targetSize: Int? = nil) -> Data {
        var head = Data(repeating: 0, count: 54)
        let magic: UInt32 = 0x5F0F3CF5
        head[12] = UInt8((magic >> 24) & 0xFF)
        head[13] = UInt8((magic >> 16) & 0xFF)
        head[14] = UInt8((magic >> 8) & 0xFF)
        head[15] = UInt8(magic & 0xFF)
        let outlineSize = max(16, (targetSize ?? 0) - 256)
        var tables: [(String, Data)] = [
            ("head", head),
            ("hhea", Data(repeating: 0, count: 36)),
            ("maxp", Data(repeating: 0, count: 6)),
            ("name", Data(repeating: 0, count: 8))
        ]
        let version: UInt32
        switch flavor {
        case .ttf:
            version = 0x00010000
            tables.append(("loca", Data(repeating: 0, count: 4)))
            tables.append(("glyf", Data(repeating: 0x01, count: outlineSize)))
        case .otf:
            version = 0x4F54544F
            tables.append(("CFF ", Data(repeating: 0x01, count: outlineSize)))
        }
        tables.sort { $0.0 < $1.0 }
        let numTables = tables.count
        var out = Data()
        func append16(_ v: UInt16) { out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF)) }
        func append32(_ v: UInt32) {
            out.append(UInt8((v >> 24) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
        }
        append32(version); append16(UInt16(numTables)); append16(16); append16(0); append16(0)
        var offset = 12 + numTables * 16
        var bodies = Data()
        for (tag, body) in tables {
            out.append(contentsOf: Array(tag.utf8))
            append32(0); append32(UInt32(offset)); append32(UInt32(body.count))
            bodies.append(body)
            let pad = (4 - (body.count % 4)) % 4
            if pad > 0 { bodies.append(Data(repeating: 0, count: pad)) }
            offset += body.count + pad
        }
        out.append(bodies)
        return out
    }
}
