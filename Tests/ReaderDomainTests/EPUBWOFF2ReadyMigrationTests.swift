import Foundation
import GRDB
import Testing
@testable import ReaderDomain

struct EPUBWOFF2ReadyMigrationTests {
    private static let fontPath = "OPS/body.woff2"
    private static let chapter = "OPS/two.xhtml"

    private struct Progress: Decodable, FetchableRecord, Equatable, Sendable {
        let bookID: String
        let versionID: String
        let unit: String
        let anchor: Data
        let sessionID: String
        let sequence: Int64
    }

    private struct Installed: Sendable {
        let snapshot: EPUBMetadataSnapshot
        let folder: URL
        let source: URL
        let original: Data
        let position: EPUBReadingPosition
        let db: DatabaseQueue
        var id: String { position.bookID }

        func progress() async throws -> Progress {
            try #require(try await db.read { db in
                try Progress.fetchOne(db, sql: "SELECT * FROM epubProgress WHERE bookID=?", arguments: [id])
            })
        }
    }

    // Build the predecessor from the *same archive*. The standalone sanitizer has no
    // conversion transaction and deliberately omits WOFF2. Stage its actual XHTML,
    // manifest, node pack and resources; never edit a new Ready's metadata to look old.
    private func installPredecessor(_ f: EPUBLibraryFixture, markedCurrent: Bool = false,
                                    differentNodes: Bool = false) async throws -> Installed {
        let page = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title><style>
        @font-face { font-family: Body; src: url('body.woff2') format('woff2'); }
        p { font-family: Body, serif; }
        </style></head><body><h1 id="heading">Two</h1><p>A😀e\u{301} body</p></body></html>
        """
        let chapters = [EPUBSyntheticChapter(id: "one", path: "one.xhtml", title: "One"),
                        EPUBSyntheticChapter(id: "two", path: "two.xhtml", title: "Two", bodyXHTML: page)]
        let ticket = UUID()
        try await f.store.beginImport(ticket)
        let archive = await f.store.epubStagingURL(ticket: ticket)
        let title = "Synthetic WOFF2 migration"
        try EPUBTestSupport.writeEPUB3(at: archive, title: title, chapters: chapters,
            manifestExtra: "<item id=\"face\" href=\"body.woff2\" media-type=\"font/woff2\"/>",
            extraEntries: [(Self.fontPath, WOFF2TestFont.data)])
        let original = try Data(contentsOf: archive)
        let work = await f.store.epubWorkURL(id: ticket)
        defer { try? FileManager.default.removeItem(at: work) }
        let extraction = try EPUBArchive.extract(archiveURL: archive, to: work)
        let spine = chapters.map { "OPS/" + $0.path }
        let manifest = [spine[0]: "application/xhtml+xml", spine[1]: "application/xhtml+xml", Self.fontPath: "font/woff2"]
        var resources: [EPUBResource] = [], nodes: [String: [String]] = [:]
        var compatibility: EPUBStyleCompatibility?
        for path in spine {
            let url = work.appendingPathComponent(path)
            var input = try Data(contentsOf: url)
            if differentNodes && path == spine[0] {
                // A consistent old Ready but a different text node in the *unanchored* chapter.
                input = Data(String(decoding: input, as: UTF8.self).replacingOccurrences(of: "结尾段落", with: "其他段落").utf8)
            }
            let document = try EPUBContentPolicy.sanitizeXHTML(data: input, path: path,
                manifestByPath: manifest, spineSet: Set(spine), destination: work)
            #expect(document.referencedFonts.isEmpty)
            #expect(!String(decoding: document.xhtmlData, as: UTF8.self).contains("@font-face"))
            try document.xhtmlData.write(to: url)
            resources.append(.init(path: path, mediaType: "application/xhtml+xml",
                sha256: EPUBResourceStore.digest(document.xhtmlData), byteCount: document.xhtmlData.count))
            nodes[path] = document.textNodes
            if path == Self.chapter { compatibility = document.styleCompatibility }
        }
        #expect(compatibility?.fontDiagnostics.contains { $0.format == .woff2 && $0.outcome == .unsupportedFormat } == true)
        let old = EPUBPackage(sourceSHA256: extraction.sourceSHA256, title: title, spine: spine,
            navigation: chapters.map { .init(title: $0.title, path: "OPS/" + $0.path, fragment: $0.headingID, depth: 0) },
            resources: resources, textNodes: nodes, coverPath: nil, authorStyleRevision: 6,
            styleCompatibility: compatibility, woff2Revision: markedCurrent ? .boundedSFNT : nil)
        let root = await f.store.epubReadyURL()
        let staged = try await EPUBContentPool.shared.stageReady(publication: .init(package: old, resourceRoot: work), root: root)
        let compact = staged.publication.package
        let directory = try #require(compact.ready?.directory)
        let folder = root.appendingPathComponent(directory)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("resources/" + Self.fontPath).path))
        let book = LibraryBook(id: old.sourceSHA256, title: title, encodingRaw: "epub", versionID: old.versionID,
                               byteCount: original.count, utf16Count: 0, format: .epub)
        _ = try await f.store.commitEPUB(ticket: ticket, proposed: book, package: compact, cover: nil)
        await EPUBContentPool.shared.commitReady(directory: directory, root: root)
        await staged.release()
        let snapshot = try await f.store.storedEPUBSnapshot(bookID: book.id)
        #expect(snapshot.package.needsWOFF2Upgrade == !markedCurrent)
        let node = try #require(nodes[Self.chapter]?.firstIndex(where: { $0.contains("A😀") }))
        let position = EPUBReadingPosition(bookID: book.id, versionID: old.versionID, path: Self.chapter,
                                           node: node, utf16Offset: 3, viewportOffset: -12.5)
        let permit = try await f.store.reserveReaderOpen(bookID: book.id)
        let session = try await f.store.beginEPUB(permit, snapshot: snapshot).session
        try await f.store.confirmReaderOpen(permit, session: session)
        await f.store.endReaderOpen(permit)
        let token = try await f.store.beginEPUBNavigation(session: session, path: position.path)
        #expect(try await f.store.markEPUBReady(session: session, token: token))
        try await f.store.finishEPUB(session: session, position: position, sequence: 13, token: token, preferences: ReaderPreferences())
        return Installed(snapshot: snapshot, folder: folder, source: try await f.store.epubFileURL(bookID: book.id),
                         original: original, position: position, db: try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path))
    }

    @Test func omittedWOFF2ReadyRefreshesOnceWithoutMovingProgress() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let old = try await installPredecessor(f)
        let row = try await old.progress()
        #expect(row.sequence == 13)
        #expect(try JSONDecoder().decode(EPUBReadingPosition.self, from: row.anchor) == old.position)
        let pack = try Data(contentsOf: old.folder.appendingPathComponent(EPUBReadyArtifact.nodeFile))
        var nodes: [String: [String]] = [:]
        for path in old.snapshot.package.spine { nodes[path] = try #require(try old.snapshot.package.nodes(at: path)) }

        let service = LibraryService(store: try LibraryStore(root: f.managed))
        let opened = try await service.openEPUB(id: old.id)
        let current = opened.publication.package
        let font = try #require(current.resource(at: Self.fontPath))
        let data = try EPUBResourceStore.data(path: font.path, publication: opened.publication)
        #expect(try EPUBAuthorStyles.verifyFontData(data, declaredMediaType: font.mediaType) == font.mediaType)
        #expect(["font/ttf", "font/otf"].contains(font.mediaType))
        #expect(font.byteCount == data.count && font.sha256 == EPUBResourceStore.digest(data))
        #expect(data != WOFF2TestFont.data)
        let cssChapter = try EPUBResourceStore.data(path: Self.chapter, publication: opened.publication)
        #expect(String(decoding: cssChapter, as: UTF8.self).contains("@font-face"))
        #expect(current.woff2Revision == .boundedSFNT && !current.needsAuthorStyleUpgrade)
        #expect(opened.openingTimings.readyPreparationOccurred && !opened.reusedResources)
        #expect(current.versionID == old.position.versionID && current.sourceSHA256 == old.id)
        #expect(current.spine == old.snapshot.package.spine)
        for path in current.spine { #expect(try current.nodes(at: path) == nodes[path]) }
        let directory = try #require(current.ready?.directory)
        let root = await f.store.epubReadyURL()
        #expect(try Data(contentsOf: root.appendingPathComponent(directory).appendingPathComponent(EPUBReadyArtifact.nodeFile)) == pack)
        #expect(!FileManager.default.fileExists(atPath: old.folder.path))
        #expect(opened.reading.position == old.position && !opened.reading.ignoredIncompatibleProgress)
        try await opened.abandon()
        let again = try await LibraryService(store: LibraryStore(root: f.managed)).openEPUB(id: old.id)
        #expect(again.reusedResources && !again.openingTimings.readyPreparationOccurred)
        #expect(again.publication.package.ready == current.ready && again.reading.position == old.position)
        try await again.abandon()
        #expect(try await old.progress() == row)
        #expect(try Data(contentsOf: old.source) == old.original)
    }

    @Test func unmarkedRevisionSixReadyWithoutWOFF2EvidenceIsReused() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let book = try await f.install(f.archive()).book
        let before = try await f.store.storedEPUBSnapshot(bookID: book.id)
        #expect(before.package.authorStyleRevision == 6 && before.package.woff2Revision == nil)
        #expect(!before.package.needsAuthorStyleUpgrade)
        let opened = try await LibraryService(store: LibraryStore(root: f.managed)).openEPUB(id: book.id)
        #expect(opened.reusedResources && !opened.openingTimings.readyPreparationOccurred)
        #expect(opened.publication.package.ready == before.package.ready)
        try await opened.abandon()
        #expect(try await f.store.storedEPUBSnapshot(bookID: book.id).metadataSHA256 == before.metadataSHA256)
    }

    enum Failure: CaseIterable, Sendable { case source, oldResource, nodePack, differentNodes, progress, publication, currentRevision, currentProgress }

    @Test(arguments: Failure.allCases)
    func refreshRejectsDamageAndRollsBack(_ failure: Failure) async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let old = try await installPredecessor(f, markedCurrent: failure == .currentRevision || failure == .currentProgress,
                                               differentNodes: failure == .differentNodes)
        let intactRow = try await old.progress()
        let root = await f.store.epubReadyURL()
        let resource = old.folder.appendingPathComponent("resources/" + Self.chapter)
        let pack = old.folder.appendingPathComponent(EPUBReadyArtifact.nodeFile)
        func damage(_ url: URL) throws {
            var data = try Data(contentsOf: url)
            data[data.count - 1] ^= 1 // preserve size, not SHA
            try data.write(to: url)
        }
        switch failure {
        case .source: try damage(old.source)
        case .oldResource, .currentRevision: try damage(resource)
        case .nodePack: try damage(pack)
        case .differentNodes: break // Constructed and checksummed before publication.
        case .progress, .currentProgress:
            // Valid JSON and matching book/version, but inside the emoji's surrogate pair.
            let invalid = EPUBReadingPosition(bookID: old.id, versionID: old.position.versionID, path: Self.chapter,
                                              node: old.position.node, utf16Offset: 2)
            let bytes = try JSONEncoder().encode(invalid)
            try await old.db.write { db in
                try db.execute(sql: "UPDATE epubProgress SET anchor=? WHERE bookID=?", arguments: [bytes, old.id])
            }
        case .publication:
            // Abort the SECOND write, after metadata update, forcing actual transaction rollback.
            try await old.db.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_refresh BEFORE UPDATE ON epubReadyVersions
                    BEGIN SELECT RAISE(ABORT, 'synthetic ready publication failure'); END
                    """)
            }
        }
        let before = try await old.progress(), source = try Data(contentsOf: old.source)
        let xhtml = try Data(contentsOf: resource), nodes = try Data(contentsOf: pack)
        let service = LibraryService(store: try LibraryStore(root: f.managed))
        switch failure {
        case .publication:
            await #expect(throws: DatabaseError.self) { _ = try await service.openEPUB(id: old.id) }
        case .source:
            await #expect(throws: LibraryError.changedFile) { _ = try await service.openEPUB(id: old.id) }
        case .progress, .currentProgress:
            await #expect(throws: EPUBError.invalidPosition) { _ = try await service.openEPUB(id: old.id) }
        case .oldResource, .nodePack, .differentNodes, .currentRevision:
            await #expect(throws: EPUBError.corruptResource) { _ = try await service.openEPUB(id: old.id) }
        }
        #expect(try await f.store.storedEPUBSnapshot(bookID: old.id).metadataSHA256 == old.snapshot.metadataSHA256)
        #expect(try await f.store.referencedEPUBReadyDirectories() == [old.folder.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [old.folder.lastPathComponent])
        #expect(try await f.store.book(id: old.id)?.activeSession == nil)
        #expect(try await old.progress() == before)
        if failure != .progress && failure != .currentProgress { #expect(before == intactRow) }
        #expect(try Data(contentsOf: old.source) == source)
        #expect(try Data(contentsOf: resource) == xhtml)
        #expect(try Data(contentsOf: pack) == nodes)
        if failure == .publication {
            try await old.db.write { db in try db.execute(sql: "DROP TRIGGER reject_refresh") }
            let retry = try await service.openEPUB(id: old.id)
            #expect(retry.openingTimings.readyPreparationOccurred && retry.reading.position == old.position)
            try await retry.abandon()
            #expect(try await old.progress() == intactRow)
        }
    }
}
