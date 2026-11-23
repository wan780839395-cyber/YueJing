import Foundation
import Testing
@testable import ReaderDomain

struct EPUBWOFF2ResourceTests {
    private let path = "OPS/Fonts/box.woff2"
    private let unused = "OPS/Fonts/unused.woff2"
    private let chapter = "OPS/c.xhtml"
    // Pinned output from the project's C decoder, not from the source TTF encoder.
    private let expectedSHA = "bbea2f6bd2d701dd5dae124a2808a306b98d13b035f628836301813b8bf27eac"
    private let sfntCount = 716

    @Test func importAndColdReopenPublishOnlyValidatedSFNT() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = WOFF2TestFont.data
        let sfnt = try EPUBWOFF2Decoder.decode(source, inputRemaining: source.count, outputRemaining: sfntCount)
        #expect(EPUBResourceStore.digest(sfnt) == expectedSHA)
        #expect(try EPUBAuthorStyles.verifyFontData(sfnt, declaredMediaType: "font/woff2") == "font/ttf")
        #expect(throws: EPUBError.unsupportedContent) {
            try EPUBAuthorStyles.verifyFontData(source, declaredMediaType: "font/woff2")
        }
        let archive = try writeBook(under: f.root, font: source)
        let original = try Data(contentsOf: archive)
        let receipt = try await f.install(archive)
        let first = try await f.service.openEPUB(id: receipt.book.id)
        try checkPublication(first.publication, sfnt: sfnt)
        try await first.close(position: nil, sequence: 1, token: nil, preferences: first.preferences)

        let fresh = LibraryService(store: try LibraryStore(root: f.managed))
        let reopened = try await fresh.openEPUB(id: receipt.book.id)
        #expect(reopened.reading.session.id != first.reading.session.id)
        try checkPublication(reopened.publication, sfnt: sfnt)
        let managedSource = try await f.store.epubFileURL(bookID: receipt.book.id)
        #expect(try Data(contentsOf: managedSource) == original)
        #expect(try Data(contentsOf: archive) == original)
        try await reopened.abandon()
    }

    @Test func truncatedContainerNeverPublishesAFont() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try writeBook(under: root, font: Data(WOFF2TestFont.data.dropLast()))
        let destination = root.appendingPathComponent("prepared")
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
        #expect(package.resource(at: path) == nil)
        #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == true)
        #expect(package.textNodes[chapter] == ["AB"])
        let publication = EPUBPublication(package: package, resourceRoot: destination)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(path: path, publication: publication) }
    }

    @Test func oversizedReconstructionAbortsPackageWithoutPublication() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        var font = WOFF2TestFont.data
        font.replaceSubrange(16..<20, with: [0x00, 0x80, 0x00, 0x01]) // totalSfntSize = 8 MiB + 1
        let archive = try writeBook(under: root, font: font)
        let original = try Data(contentsOf: archive)
        let destination = root.appendingPathComponent("rejected")
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: archive) == original)
    }

    @Test func bridgeEnforcesRemainingInputAndOutputIndependently() throws {
        let font = WOFF2TestFont.data
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBWOFF2Decoder.decode(font, inputRemaining: font.count - 1, outputRemaining: sfntCount)
        }
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBWOFF2Decoder.decode(font, inputRemaining: font.count, outputRemaining: sfntCount - 1)
        }
    }

    @Test func cancelledBridgeDoesNotReturnData() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let font = WOFF2TestFont.data
            return try EPUBWOFF2Decoder.decode(font, inputRemaining: font.count, outputRemaining: 716)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func invalidSubsetDoesNotGrantReconstructedFontCapability() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try writeBook(under: root, font: WOFF2TestFont.data, descriptor: ";unicode-range:U+110000")
        let destination = root.appendingPathComponent("subset")
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
        #expect(package.resource(at: path) == nil)
        #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == true)
        #expect(package.textNodes[chapter] == ["AB"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path))
    }

    private func checkPublication(_ publication: EPUBPublication, sfnt: Data) throws {
        let package = publication.package
        let resource = try #require(package.resource(at: path))
        // EPUBResource classifies by canonical mediaType; the ZIP suffix is not a served type.
        #expect(EPUBAuthorStyles.allowedFontMediaTypes.contains(resource.mediaType))
        #expect(resource.mediaType == "font/ttf")
        #expect(resource.sha256 == expectedSHA && resource.byteCount == sfntCount)
        #expect(try EPUBResourceStore.data(path: path, publication: publication) == sfnt)
        #expect(!EPUBAuthorStyles.isAllowedServedMediaType("font/woff2"))
        let rawSHA = EPUBResourceStore.digest(WOFF2TestFont.data)
        #expect(!package.resources.contains { $0.mediaType == "font/woff2" || $0.sha256 == rawSHA })
        let diagnostics = try #require(package.styleCompatibility?.fontDiagnostics)
        #expect(diagnostics.contains { $0.source == .embedded && $0.format == .woff2 && $0.outcome == .convertedWOFF })
        #expect(package.resource(at: unused) == nil)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(path: unused, publication: publication) }
        let html = String(decoding: try EPUBResourceStore.data(path: chapter, publication: publication), as: UTF8.self)
        #expect(html.contains("@font-face") && html.contains("/\(path)"))
        #expect(try package.nodes(at: chapter) == ["AB"])
    }

    private func writeBook(under root: URL, font: Data, descriptor: String = "") throws -> URL {
        let body = """
        <html xmlns='http://www.w3.org/1999/xhtml'><head><title>Box</title><style>
        @font-face{font-family:Box;src:url(Fonts/box.woff2) format('woff2')\(descriptor)}p{font-family:Box}
        </style></head><body><p id='heading'>AB</p></body></html>
        """
        return try EPUBTestSupport.writeEPUB3(at: root.appendingPathComponent("box.epub"),
            chapters: [.init(id: "c", path: "c.xhtml", title: "Box", bodyXHTML: body)],
            manifestExtra: "<item id='font' href='Fonts/box.woff2' media-type='font/woff2'/><item id='unused' href='Fonts/unused.woff2' media-type='font/woff2'/>",
            extraEntries: [(path, font), (unused, WOFF2TestFont.data)])
    }
}
