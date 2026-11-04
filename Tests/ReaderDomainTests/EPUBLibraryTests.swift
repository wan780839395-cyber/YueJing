import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import TXTCore
import UniformTypeIdentifiers
import ZIPFoundation
@testable import ReaderDomain

struct EPUBLibraryFixture: Sendable {
    let root: URL
    let managed: URL
    let store: LibraryStore
    let service: LibraryService
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EPUB-library-" + UUID().uuidString)
        managed = root.appendingPathComponent("Managed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryStore(root: managed); service = LibraryService(store: store)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func archive(title: String = "Synthetic EPUB", cover: Data? = nil, broken: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".epub")
        let zip = try Archive(url: url, accessMode: .create)
        let coverItem = cover == nil ? "" : "<item id=\"cover\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>"
        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:fixture</dc:identifier><dc:title>\(title)</dc:title><dc:language>zh</dc:language></metadata>
        <manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\(coverItem)</manifest>
        <spine><itemref idref="one"/><itemref idref="two"/></spine></package>
        """
        let page: (String) -> String = { title in
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Chapter</title></head><body><h1 id=\"heading\">\(title)</h1><p>A😀e\u{301} tail</p><p>Last paragraph.</p></body></html>"
        }
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
            ("OPS/book.opf", Data(package.utf8)),
            ("OPS/one.xhtml", Data((broken ? "<html><broken>" : page("First chapter")).utf8)),
            ("OPS/two.xhtml", Data(page("Second chapter").utf8)),
            ("OPS/nav.xhtml", Data("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml#heading\">First</a></li><li><a href=\"two.xhtml#heading\">Second</a></li></ol></nav></body></html>".utf8))
        ]
        if let cover { entries.append(("OPS/cover.png", cover)) }
        for (path, data) in entries {
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: path == "mimetype" ? .none : .deflate) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
        return url
    }
    func install(_ url: URL, ticket: UUID = UUID()) async throws -> ImportReceipt {
        let result = try await service.prepareReadingImport(url: url, ticket: ticket, budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = result else { throw EPUBError.invalidPackage }
        return receipt
    }
    static func image(width: Int = 1200, height: Int = 800) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func position(_ reader: OpenedEPUBReader, path: String? = nil, offset: Int = 0) throws -> EPUBReadingPosition {
        let package = reader.publication.package, href = path ?? reader.publication.package.spine[0]
        let nodes = try #require(package.textNodes[href])
        let index = try #require(nodes.firstIndex(where: { $0.contains("A😀") }))
        return EPUBReadingPosition(bookID: reader.book.id, versionID: reader.book.versionID, path: href, node: index, utf16Offset: offset)
    }
}

struct EPUBLibraryTests {
    @Test func epubOriginalArchiveAndValidatedResourcesSurviveReopen() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = try f.archive(), bytes = try Data(contentsOf: source)
        let receipt = try await f.install(source)
        #expect(receipt.book.format == .epub && receipt.book.encoding == nil && receipt.book.utf16Count == 0)
        let stored = try await f.store.epubFileURL(bookID: receipt.book.id)
        #expect(try Data(contentsOf: stored) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        let reader = try await f.service.openEPUB(id: receipt.book.id)
        #expect(reader.publication.package.spine == ["OPS/one.xhtml", "OPS/two.xhtml"])
        for path in reader.publication.package.spine {
            let data = try EPUBResourceStore.data(path: path, publication: reader.publication)
            #expect(String(decoding: data, as: UTF8.self).contains("yj-t"))
        }
        let folder = reader.publication.resourceRoot
        try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let fresh = LibraryService(store: try LibraryStore(root: f.managed))
        let reopened = try await fresh.openEPUB(id: receipt.book.id)
        #expect(reopened.publication.package == reader.publication.package)
        try await reopened.close(position: nil, sequence: 1, token: nil, preferences: reopened.preferences)
    }

    @Test func epubDuplicateKeepsProgressAndRepairsMissingArchive() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = try f.archive(), first = try await f.install(source)
        let reader = try await f.service.openEPUB(id: first.book.id)
        let position = try EPUBLibraryFixture.position(reader, offset: 1)
        let token = try await reader.beginNavigation(path: position.path)
        #expect(try await reader.markReady(token))
        try await reader.close(position: position, sequence: 1, token: token, preferences: reader.preferences)
        try FileManager.default.removeItem(at: await f.store.epubFileURL(bookID: first.book.id))
        let duplicate = try await f.install(source)
        #expect(duplicate.duplicate && duplicate.book.id == first.book.id)
        #expect(try await f.store.books().count == 1)
        let next = try await f.service.openEPUB(id: first.book.id)
        #expect(next.reading.position == position)
        try await next.close(position: nil, sequence: 1, token: nil, preferences: next.preferences)
    }

    @Test func epubCancellationBeforeCommitLeavesNoBook() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = try f.archive(), ticket = UUID()
        _ = await f.service.cancelImport(ticket)
        await #expect(throws: CancellationError.self) { try await f.install(source, ticket: ticket) }
        #expect(try await f.store.books().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.managed.appendingPathComponent("Imports").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // Cancel after successful parsing, immediately before the store's atomic commit decision.
        let late = UUID(), staging = await f.store.epubStagingURL(ticket: late)
        let work = await f.store.epubWorkURL(id: late)
        try await f.store.beginImport(late)
        try FileManager.default.copyItem(at: source, to: staging)
        let package = try EPUBPackageParser.parse(archiveURL: staging, destination: work)
        let proposed = LibraryBook(id: package.sourceSHA256, title: package.title, encodingRaw: "epub",
            versionID: package.versionID, byteCount: (try Data(contentsOf: source)).count, utf16Count: 0, format: .epub)
        _ = await f.store.cancelImport(late)
        await #expect(throws: CancellationError.self) {
            try await f.store.commitEPUB(ticket: late, proposed: proposed, package: package, cover: nil)
        }
        #expect(try await f.store.books().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try await f.store.epubFileURL(bookID: proposed.id).path))
        #expect(FileManager.default.fileExists(atPath: staging.path))
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.removeItem(at: work)
    }

    @Test func epubCancellationAfterCommitReturnsReceipt() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = try f.archive(), ticket = UUID()
        let receipt = try await f.install(source, ticket: ticket)
        switch await f.service.cancelImport(ticket) {
        case .alreadyCommitted(let truth): #expect(truth.book == receipt.book && truth.duplicate == receipt.duplicate)
        case .cancelled: Issue.record("Committed EPUB must not become cancelled")
        }
        #expect(try await f.store.books().count == 1)
        #expect(try Data(contentsOf: await f.store.epubFileURL(bookID: receipt.book.id)) == Data(contentsOf: source))
    }

    @Test func epubFailedImportCleansOnlyItsWorkspace() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let good = try f.archive(), bad = try f.archive(broken: true)
        let receipt = try await f.install(good)
        let reader = try await f.service.openEPUB(id: receipt.book.id)
        await #expect(throws: (any Error).self) { try await f.install(bad) }
        #expect(try await f.store.books().count == 1)
        #expect(FileManager.default.fileExists(atPath: reader.publication.resourceRoot.path))
        let data = try EPUBResourceStore.data(path: "OPS/one.xhtml", publication: reader.publication)
        #expect(!data.isEmpty)
        let imports = try FileManager.default.contentsOfDirectory(at: f.managed.appendingPathComponent("Imports"), includingPropertiesForKeys: nil)
        #expect(imports == [reader.publication.resourceRoot])
        try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
        // Force failure after the source rename; SQLite and the renamed file must roll back.
        let queue = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_epub BEFORE INSERT ON epubPackages BEGIN SELECT RAISE(ABORT,'synthetic rollback'); END")
        }
        let rejected = try f.archive(title: "Rollback only"), rejectedID = try EPUBResourceStore.sourceDigest(rejected)
        await #expect(throws: (any Error).self) { try await f.install(rejected) }
        #expect(try await f.store.books().count == 1)
        #expect(try await f.store.book(id: rejectedID) == nil)
        #expect(!FileManager.default.fileExists(atPath: try await f.store.epubFileURL(bookID: rejectedID).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.managed.appendingPathComponent("Imports").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: rejected.path))
    }

    @Test func epubV6MigrationPreservesTXTProgressBookmarksAndPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path)
        try LibrarySchema.migrator().migrate(queue, upTo: "v5-bookmark-names")
        let id = String(repeating: "a", count: 64), prefs = ReaderPreferences(fontSize: 26, lineSpacing: 11, theme: .dark)
        let preferenceData = try JSONEncoder().encode(prefs)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO books(id,title,encodingRaw,versionID,byteCount,utf16Count,addedAt) VALUES(?,'Legacy','UTF-8','v',100,100,0)", arguments: [id])
            try db.execute(sql: "INSERT INTO progress VALUES(?,'v','raw-byte-v1',12,0.25,'old',4)", arguments: [id])
            try db.execute(sql: "INSERT INTO bookmarks(id,bookID,versionID,unit,rawByteOffset,createdAt,customName) VALUES('bookmark',?,'v','raw-byte-v1',12,1,'Keep name')", arguments: [id])
            try db.execute(sql: "INSERT INTO preferences VALUES(1,?)", arguments: [preferenceData])
        }
        let store = try LibraryStore(root: root)
        #expect(try await store.book(id: id)?.format == .txt)
        #expect(try await store.preferences() == prefs)
        let reading = try await store.beginReading(bookID: id, versionID: "v")
        #expect(reading.anchor?.rawByteOffset == 12 && reading.anchor?.lineFraction == 0.25)
        let counts = try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks WHERE customName='Keep name' AND unit='raw-byte-v1'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM epubProgress"),
             try String.fetchOne(db, sql: "SELECT format FROM bookFormats WHERE bookID=?", arguments: [id]))
        }
        #expect(counts.0 == 1 && counts.1 == 0 && counts.2 == "txt")
        await #expect(throws: (any Error).self) {
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO epubProgress VALUES(?,'v','raw-byte-v1',X'00','s',1)", arguments: [id])
            }
        }
    }

    @Test func epubCoverThumbnailBoundsAndDamagedFallback() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let image = try EPUBLibraryFixture.image()
        let good = try await f.install(f.archive(cover: image))
        let bytes = try #require(try await f.store.epubCover(bookID: good.book.id))
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 512)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int ?? 999) <= 512)
        #expect(await EPUBCoverProcessor.shared.thumbnail(image) == bytes)
        let damaged = try await f.install(f.archive(title: "Damaged optional cover", cover: Data("not an image".utf8)))
        #expect(try await f.store.epubCover(bookID: damaged.book.id) == nil)
        let missing = try await f.install(f.archive(title: "No cover"))
        #expect(try await f.store.epubCover(bookID: missing.book.id) == nil)
        let reader = try await f.service.openEPUB(id: damaged.book.id)
        #expect(reader.publication.package.spine.count == 2)
        try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
    }

    @Test func epubBooksAndTXTStayIsolated() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let a = try await f.install(f.archive(title: "Book A")), b = try await f.install(f.archive(title: "Book B"))
        let reader = try await f.service.openEPUB(id: a.book.id)
        let position = try EPUBLibraryFixture.position(reader), token = try await reader.beginNavigation(path: position.path)
        #expect(try await reader.markReady(token))
        try await reader.close(position: position, sequence: 1, token: token, preferences: reader.preferences)
        let other = try await f.service.openEPUB(id: b.book.id)
        #expect(other.reading.position == nil)
        try await other.close(position: nil, sequence: 1, token: nil, preferences: other.preferences)
        let txt = f.root.appendingPathComponent("legacy.txt"), data = Data("Chapter 1\nTXT only\n".utf8)
        try data.write(to: txt)
        let txtReceipt = try await f.install(txt)
        #expect(txtReceipt.book.format == .txt)
        let txtReader = try await f.service.openReader(id: txtReceipt.book.id, budget: ReaderStoragePolicy.budget())
        #expect(txtReader.reading.anchor == nil)
        #expect(try Data(contentsOf: await f.store.fileURL(bookID: txtReceipt.book.id)) == data)
        try await txtReader.close()
        let epubSource = try f.archive(title: "Rejected by lower TXT API")
        await #expect(throws: LibraryError.notTXT) { try await f.service.prepareImport(url: epubSource, ticket: UUID()) }
        #expect(try await f.store.books().count == 3)
    }
}
