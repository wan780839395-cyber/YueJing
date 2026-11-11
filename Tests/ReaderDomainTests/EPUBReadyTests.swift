import Foundation
import GRDB
import Testing
@testable import ReaderDomain

struct EPUBReadyTests {
    @Test func readyNodePackKeepsExactNodesWithSmallManifest() throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let folder = f.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let paths = (0..<1633).map { "OPS/chapter-\($0).xhtml" }
        let text = String(repeating: "Synthetic A😀e\u{301} paragraph. ", count: 32)
        let nodes = Dictionary(uniqueKeysWithValues: paths.map { ($0, Array(repeating: text, count: 8)) })
        // Storage fixture only: does not claim a complete 1633-chapter parser/WebKit lifecycle.
        let full = EPUBPackage(sourceSHA256: String(repeating: "a", count: 64), title: "Synthetic node pack",
                               spine: paths, navigation: [], resources: [], textNodes: nodes, coverPath: nil)
        let compact = try EPUBReadyArtifact.writeNodes(package: full, folder: folder)
        #expect(compact.textNodes.isEmpty)
        #expect(try JSONEncoder().encode(compact).count < JSONEncoder().encode(full).count / 8)
        try EPUBReadyArtifact.verifyNodes(package: compact, folder: folder)
        let bound = try compact.attachingNodes(folder: folder)
        for path in [paths[0], paths[816], paths[1632]] {
            #expect(try bound.nodes(at: path) == nodes[path])
            let valid = EPUBReadingPosition(bookID: full.sourceSHA256, versionID: full.versionID,
                                            path: path, node: 0, utf16Offset: 0)
            try valid.validate(in: bound)
        }
        #expect(try bound.nodes(at: "missing.xhtml") == nil)
        #expect(try JSONEncoder().encode(bound).count == JSONEncoder().encode(compact).count)
        let reference = try #require(compact.ready)
        let corrupt = EPUBReadyReference(revision: 1, directory: reference.directory,
            legacyPackageSHA256: reference.legacyPackageSHA256, nodeBytes: reference.nodeBytes + 1,
            nodeSHA256: reference.nodeSHA256, chapters: reference.chapters)
        #expect(throws: EPUBError.corruptResource) { try EPUBReadyArtifact.validate(corrupt, package: full.withReady(corrupt)) }
    }

    @Test func readyImportColdReaderDoesNotDependOnParkedLease() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive())
        let snapshot = try await f.store.storedEPUBSnapshot(bookID: receipt.book.id)
        #expect(snapshot.package.ready != nil && snapshot.package.textNodes.isEmpty)
        let first = try await f.service.openEPUB(id: receipt.book.id)
        #expect(first.reusedResources && !first.openingTimings.readyPreparationOccurred)
        let position = try EPUBLibraryFixture.position(first, path: "OPS/two.xhtml", offset: 1)
        let token = try await first.beginNavigation(path: position.path)
        #expect(try await first.markReady(token))
        try await first.close(position: position, sequence: 1, token: token, preferences: first.preferences)
        let fresh = LibraryService(store: try LibraryStore(root: f.managed))
        let reopened = try await fresh.openEPUB(id: receipt.book.id)
        #expect(reopened.publication.resourceRoot == first.publication.resourceRoot)
        #expect(reopened.reading.position == position && reopened.reading.session.id != first.reading.session.id)
        #expect(!reopened.openingTimings.metadataDecodeReused)
        #expect(reopened.openingTimings.chapterIndexedMetadata && !reopened.openingTimings.readyPreparationOccurred)
        #expect(!reopened.openingTimings.samples.contains { $0.phase == .rebuild })
        try await reopened.abandon()
    }

    @Test func legacyMigrationPreservesProgressPreferencesAndOriginal() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await installLegacy(f)
        let before = try await f.store.storedEPUBSnapshot(bookID: receipt.book.id)
        #expect(before.package.ready == nil && !before.package.textNodes.isEmpty)
        let source = try await f.store.epubFileURL(bookID: receipt.book.id)
        let bytes = try Data(contentsOf: source)
        let permit = try await f.store.reserveReaderOpen(bookID: receipt.book.id)
        let start = try await f.store.beginEPUB(permit, snapshot: before)
        try await f.store.confirmReaderOpen(permit, session: start.session)
        await f.store.endReaderOpen(permit)
        let path = before.package.spine[1]
        let position = EPUBReadingPosition(bookID: receipt.book.id, versionID: receipt.book.versionID,
                                           path: path, node: 0, utf16Offset: 1)
        let token = try await f.store.beginEPUBNavigation(session: start.session, path: path)
        #expect(try await f.store.markEPUBReady(session: start.session, token: token))
        let prefs = ReaderPreferences(fontSize: 26, lineSpacing: 11, theme: .dark)
        try await f.store.finishEPUB(session: start.session, position: position, sequence: 1, token: token, preferences: prefs)
        let opened = try await f.service.openEPUB(id: receipt.book.id)
        #expect(opened.openingTimings.readyPreparationOccurred && opened.openingTimings.chapterIndexedMetadata)
        #expect(opened.reading.position == position && opened.preferences == prefs)
        #expect(try Data(contentsOf: source) == bytes)
        for chapter in before.package.spine { #expect(try opened.publication.package.nodes(at: chapter) == before.package.textNodes[chapter]) }
        try await opened.abandon()
        let again = try await f.service.openEPUB(id: receipt.book.id)
        #expect(!again.openingTimings.readyPreparationOccurred)
        try await again.abandon()
    }

    @Test func readyUnvisitedNodeDamageIsDetectedBeforeOpenAndRepairedWithLeaseIsolation() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive())
        let old = try await f.service.openEPUB(id: receipt.book.id)
        let pin = try await old.leaseForRenderer()
        try await old.abandon()
        let folder = old.publication.resourceRoot.deletingLastPathComponent()
        let nodeFile = folder.appendingPathComponent(EPUBReadyArtifact.nodeFile)
        var data = try Data(contentsOf: nodeFile)
        data[data.index(before: data.endIndex)] ^= 1 // Last chapter, same size; current chapter was already cached.
        try data.write(to: nodeFile)
        let snapshot = try await f.store.storedEPUBSnapshot(bookID: receipt.book.id)
        let source = try await f.store.epubFileURL(bookID: receipt.book.id)
        let root = await f.store.epubReadyURL()
        await #expect(throws: EPUBError.corruptResource) {
            try await EPUBContentPool.shared.acquireReady(archive: source, snapshot: snapshot, root: root)
        }
        let repaired = try await f.service.openEPUB(id: receipt.book.id)
        #expect(!repaired.reusedResources && repaired.openingTimings.readyPreparationOccurred)
        #expect(repaired.publication.resourceRoot != old.publication.resourceRoot)
        #expect(FileManager.default.fileExists(atPath: nodeFile.path))
        await #expect(throws: EPUBError.staleSession) { try await pin.duplicate() }
        await pin.release()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try EPUBReadyArtifact.verifyNodes(package: repaired.publication.package,
                                         folder: repaired.publication.resourceRoot.deletingLastPathComponent())
        try await repaired.abandon()
    }

    @Test func readyPublicationRollbackAndReconciliationProtectLiveVersions() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await installLegacy(f)
        let previous = try await f.store.storedEPUBSnapshot(bookID: receipt.book.id)
        let source = try await f.store.epubFileURL(bookID: receipt.book.id)
        let root = await f.store.epubReadyURL()
        let work = await f.store.epubWorkURL(id: UUID())
        let pool = EPUBContentPool()
        let staged = try await pool.rebuildReady(archive: source, expected: previous.package, root: root, work: work)
        let folder = staged.publication.resourceRoot.deletingLastPathComponent()
        let orphan = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let unknown = root.appendingPathComponent("not-owned")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try await pool.reconcileReady(root: root, referenced: [])
        #expect(FileManager.default.fileExists(atPath: folder.path)) // Pending lease, not yet in DB.
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        let queue = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_ready BEFORE UPDATE OF metadata ON epubPackages BEGIN SELECT RAISE(ABORT,'synthetic Ready failure'); END")
        }
        await #expect(throws: (any Error).self) { try await f.store.publishEPUBReady(bookID: receipt.book.id, previous: previous, lease: staged) }
        #expect(try await f.store.storedEPUBSnapshot(bookID: receipt.book.id).package == previous.package)
        #expect(try await f.store.referencedEPUBReadyDirectories().isEmpty)
        await staged.release()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func readyManifestMutationCannotBeBlessedByRepair() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive(title: "Ready A"))
        let id = receipt.book.id
        let queue = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
        let bytes = try #require(try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [id])
        })
        let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Ready A", with: "Ready B").utf8)
        #expect(bytes.count == changed.count && bytes != changed)
        try await queue.write { db in try db.execute(sql: "UPDATE epubPackages SET metadata=? WHERE bookID=?", arguments: [changed, id]) }
        await #expect(throws: EPUBError.corruptResource) { try await f.service.openEPUB(id: id) }
        let after = try await queue.read { db in try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [id]) }
        #expect(after == changed) // Do not rewrite invalid metadata to manufacture success.
        try await queue.write { db in try db.execute(sql: "UPDATE epubPackages SET metadata=? WHERE bookID=?", arguments: [bytes, id]) }
        let opened = try await f.service.openEPUB(id: id)
        #expect(!opened.openingTimings.readyPreparationOccurred)
        try await opened.abandon()
    }

    @Test func boundedParallelVerificationMatchesSerialIntegrityAndCancellation() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive()
        let folder = f.root.appendingPathComponent("verified")
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: folder)
        let publication = EPUBPublication(package: package, resourceRoot: folder)
        try EPUBPublicationCache.verifyResources(publication)
        try await EPUBPublicationCache.verifyResourcesConcurrently(publication)
        let path = folder.appendingPathComponent(package.spine.last!)
        let original = try Data(contentsOf: path)
        var damaged = original; damaged[0] ^= 1
        try damaged.write(to: path)
        #expect(throws: EPUBError.corruptResource) { try EPUBPublicationCache.verifyResources(publication) }
        await #expect(throws: EPUBError.corruptResource) { try await EPUBPublicationCache.verifyResourcesConcurrently(publication) }
        try original.write(to: path)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await EPUBPublicationCache.verifyResourcesConcurrently(publication)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let outside = f.root.appendingPathComponent("outside.xhtml")
        try original.write(to: outside)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        await #expect(throws: EPUBError.corruptResource) { try await EPUBPublicationCache.verifyResourcesConcurrently(publication) }
        #expect(try Data(contentsOf: outside) == original)
    }

    private func installLegacy(_ f: EPUBLibraryFixture) async throws -> ImportReceipt {
        let source = try f.archive(), ticket = UUID()
        try await f.store.beginImport(ticket)
        let staging = await f.store.epubStagingURL(ticket: ticket)
        try FileManager.default.copyItem(at: source, to: staging)
        let work = await f.store.epubWorkURL(id: ticket)
        defer { try? FileManager.default.removeItem(at: work) }
        let package = try EPUBPackageParser.parse(archiveURL: staging, destination: work)
        let bytes = try Data(contentsOf: staging).count
        let book = LibraryBook(id: package.sourceSHA256, title: package.title, encodingRaw: "epub",
                               versionID: package.versionID, byteCount: bytes, utf16Count: 0, format: .epub)
        return try await f.store.commitEPUB(ticket: ticket, proposed: book, package: package, cover: nil)
    }
}
