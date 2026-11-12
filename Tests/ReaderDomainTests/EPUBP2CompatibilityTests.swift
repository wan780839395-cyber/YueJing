import Foundation
import Testing
@testable import ReaderDomain

struct EPUBP2CompatibilityTests {
    @Test func staticMediaModifiersAgreeAcrossAttributesBlocksAndImports() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("p { color: #123456; }".utf8).write(to: root.appendingPathComponent("OPS/shared.css"))
        let cases: [(String, Bool, Bool)] = [
            ("only screen", true, false), ("ONLY all", true, false),
            ("not print", true, false), ("not screen", false, false),
            ("not all", false, false), ("only print", false, false),
            ("print, only screen", true, false),
            ("not unknown", false, true), ("only", false, true),
            ("not screen and (min-width: 1px)", false, true),
            ("only screen and (orientation: portrait)", false, true),
            ("screen, (min-width: 1px)", true, true)
        ]
        for (condition, emits, unsupported) in cases {
            let evaluation = EPUBAuthorStyles.evaluateMediaCondition(condition)
            #expect(evaluation.emitRules == emits)
            for element in ["<style media=\"\(condition)\">p { color: #123456; }</style>",
                            "<link rel=\"stylesheet\" href=\"shared.css\" media=\"\(condition)\"/>"] {
                let document = try EPUBContentPolicy.sanitizeXHTML(
                    data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>\(element)</head><body><p>Text</p></body></html>".utf8),
                    path: "OPS/c.xhtml", manifestByPath: ["OPS/shared.css": "text/css"],
                    spineSet: ["OPS/c.xhtml"], destination: root
                )
                #expect(String(decoding: document.xhtmlData, as: UTF8.self).contains("#123456") == emits)
                #expect(document.textNodes == ["Text"])
            }
            #expect(evaluation.hasUnsupportedCondition == unsupported)
            for css in ["@media \(condition) { p { color: #123456; } }",
                        "@import 'shared.css' \(condition);"] {
                let result = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                    css, sourcePath: "OPS/book.css", documentPath: "OPS/c.xhtml",
                    manifestByPath: ["OPS/shared.css": "text/css"], destination: root
                )
                #expect(result.css.contains("#123456") == emits)
                #expect(result.styleCompatibility.issues.contains(.unsupportedStyleCondition) == unsupported)
            }
        }
        for depth in [8, 9] {
            let css = String(repeating: "@media only screen {", count: depth) +
                "p { color: #123456; }" + String(repeating: "}", count: depth)
            if depth == 8 {
                let result = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                    css, sourcePath: "OPS/s.css", documentPath: "OPS/c.xhtml", manifestByPath: [:], destination: root
                )
                #expect(result.css.contains("#123456"))
            } else {
                #expect(throws: EPUBStyleProcessingError.complexityExceeded) {
                    _ = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                        css, sourcePath: "OPS/s.css", documentPath: "OPS/c.xhtml", manifestByPath: [:], destination: root
                    )
                }
            }
        }
        // A false condition must still audit dangerous payloads, including import URLs.
        for css in ["@media not screen { p { background: url(https://invalid.example/a); } }",
                    "@import 'https://invalid.example/a.css' only print;"] {
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                    css, sourcePath: "OPS/book.css", documentPath: "OPS/c.xhtml",
                    manifestByPath: [:], destination: root
                )
            }
        }
    }

    @Test func sharedASTCacheBoundsDoNotChangeCascadeScopeOrCancellation() async throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        let css = "p { color: #123456; }"
        var manifest: [String: String] = [:]
        for index in 0...64 {
            let path = "OPS/s\(index).css"
            manifest[path] = "text/css"
            try Data(css.utf8).write(to: root.appendingPathComponent(path))
        }
        let cache = EPUBAuthorStyles.ValidationCache()
        func collect(_ index: Int, cache: EPUBAuthorStyles.ValidationCache?) throws -> EPUBSanitizedDocument {
            let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><link rel=\"stylesheet\" href=\"s\(index).css\"/><style>p { color: #654321; }</style><link rel=\"stylesheet\" href=\"s\(index).css\"/></head><body><p>Text</p></body></html>"
            return try EPUBContentPolicy.sanitizeXHTML(
                data: Data(xhtml.utf8), path: "OPS/c\(index).xhtml", manifestByPath: manifest,
                spineSet: ["OPS/c\(index).xhtml"], destination: root, styleCache: cache
            )
        }
        for index in 0...64 {
            let cached = try collect(index, cache: cache)
            let uncached = try collect(index, cache: nil)
            #expect(cached.xhtmlData == uncached.xhtmlData)
            #expect(cached.textNodes == ["Text"])
        }
        #expect(cache.parsedStylesheets.count == 64)
        #expect(cache.parsedStylesheetSourceBytes == 64 * css.utf8.count)
        #expect(cache.parsedStylesheets["OPS/s64.css"] == nil)
        // Source-byte cap is separate from the entry cap; admission failure is not a book failure.
        let byteCache = EPUBAuthorStyles.ValidationCache()
        byteCache.retainStylesheet(at: "a", byteCount: EPUBAuthorStyles.maxExternalCSSBytes, items: [])
        byteCache.retainStylesheet(at: "b", byteCount: EPUBAuthorStyles.maxExternalCSSBytes, items: [])
        byteCache.retainStylesheet(at: "c", byteCount: 1, items: [])
        #expect(byteCache.parsedStylesheets.count == 2)
        #expect(byteCache.parsedStylesheetSourceBytes == EPUBAuthorStyles.maxTotalChapterCSSBytes)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let collector = EPUBAuthorStyles.ChapterCollector(
                documentPath: "OPS/c.xhtml", scopeID: "yjtest", manifestByPath: manifest,
                destination: root, cache: EPUBAuthorStyles.ValidationCache()
            )
            try collector.addExternalStylesheet(href: "s0.css")
        }
        do {
            try await task.value
            Issue.record("Cancelled stylesheet collection must not publish a result")
        } catch is CancellationError {}
    }

    @Test func sanitizedGrowthRejectsBeforeRetainingAllChaptersAndCleansWorkspace() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // A small shared sheet grows after per-chapter scoping; raw archive fits, output does not.
        let css = (0..<80).map { "p.c\($0) { color: #123456; }" }.joined()
        let chapters = (0..<12).map { index in
            EPUBSyntheticChapter(id: "c\(index)", path: "c\(index).xhtml", title: "C\(index)",
                bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><link rel=\"stylesheet\" href=\"s.css\"/></head><body><p id=\"heading\">Text</p></body></html>")
        }
        let archive = root.appendingPathComponent("growth.epub")
        try EPUBTestSupport.writeEPUB3(at: archive, chapters: chapters,
            manifestExtra: "<item id=\"css\" href=\"s.css\" media-type=\"text/css\"/>",
            extraEntries: [("OPS/s.css", Data(css.utf8))])
        var limits = EPUBLimits()
        limits.expandedBytes = 32 * 1024
        let extracted = root.appendingPathComponent("raw")
        _ = try EPUBArchive.extract(archiveURL: archive, to: extracted, limits: limits)
        try FileManager.default.removeItem(at: extracted)
        let accepted = try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("accepted"))
        #expect(accepted.spine.count == chapters.count)
        #expect(accepted.resources.reduce(0) { $0 + $1.byteCount } > limits.expandedBytes)
        let destination = root.appendingPathComponent("rejected")
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBPackageParser.parse(archiveURL: archive, destination: destination, limits: limits)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func unsupportedFontsAndStructuralSelectorsNeverBecomeServedCapabilities() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["woff", "woff2"] {
            let result = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                "@font-face { font-family: F; src: url(f.\(ext)) format('\(ext)'); } p { color: #123456; }",
                sourcePath: "OPS/s.css", documentPath: "OPS/c.xhtml",
                manifestByPath: ["OPS/f.\(ext)": "font/\(ext)"], destination: root
            )
            #expect(result.referencedFonts.isEmpty)
            #expect(result.styleCompatibility.issues.contains(.fontUnavailable))
            #expect(!EPUBAuthorStyles.isAllowedServedMediaType("font/\(ext)"))
        }
        let selectors = ["p:first-child", "p:nth-child(2)", "body + section", "p:has(img)", "[data-yj-author-scope]"]
        for selector in selectors {
            let result = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                "\(selector) { color: #ff0000; } p.safe { color: #123456; }",
                sourcePath: "OPS/s.css", documentPath: "OPS/c.xhtml", manifestByPath: [:], destination: root
            )
            #expect(!result.css.contains("#ff0000"))
            #expect(result.css.contains("#123456"))
        }
    }
}
