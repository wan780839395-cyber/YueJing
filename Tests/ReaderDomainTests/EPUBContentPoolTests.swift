import Foundation
import GRDB
import Testing
@testable import ReaderDomain

struct EPUBContentPoolTests {
    @Test func recentBooksReuseIndependentVersionsWithoutCopying() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let a = try await f.install(f.archive(title: "Recent A"))
        let b = try await f.install(f.archive(title: "Recent B"))
        let first = try await f.service.openEPUB(id: a.book.id)
        #expect(!first.openingTimings.metadataDecodeReused)
        try verifySessionBreakdown(first.openingTimings)
        #expect(!first.openingTimings.summary.contains(a.book.id))
        let aRoot = first.publication.resourceRoot
        let aSession = first.reading.session.id
        let pin = try await first.leaseForRenderer()
        try await first.close(position: nil, sequence: 1, token: nil, preferences: first.preferences)
        let second = try await f.service.openEPUB(id: b.book.id)
        #expect(second.publication.resourceRoot != aRoot)
        try await second.close(position: nil, sequence: 1, token: nil, preferences: second.preferences)
        let reopened = try await f.service.openEPUB(id: a.book.id)
        #expect(reopened.publication.resourceRoot == aRoot)
        #expect(reopened.reading.session.id != aSession && reopened.reusedResources)
        #expect(!reopened.openingTimings.samples.contains { $0.phase == .rebuild || $0.phase == .cacheWrite })
        #expect(reopened.openingTimings.samples.contains { $0.phase == .sourceVerification && $0.succeeded })
        #expect(reopened.openingTimings.samples.contains { $0.phase == .warmResourceVerification && $0.succeeded })
        #expect(reopened.openingTimings.packageFingerprintReused)
        #expect(reopened.openingTimings.metadataDecodeReused)
        #expect(reopened.openingTimings.summary.contains("leased-metadata-v1"))
        #expect(reopened.openingTimings.samples.contains { $0.phase == .packageFingerprint && $0.succeeded })
        try verifySessionBreakdown(reopened.openingTimings)
        await pin.release()
        try EPUBPublicationCache.verifyResources(reopened.publication)
        try await reopened.abandon()
        let cacheRoot = await f.store.epubContentPoolURL()
        await EPUBContentPool.shared.discardUnused(root: cacheRoot)
        #expect(!FileManager.default.fileExists(atPath: aRoot.path))
        try await verifyMetadataSnapshotReuse()
        try await verifyMetadataMutationRejectsSession()
        try await verifyLeaseHeldMetadataReuse()
        try verifyResourceAttributes()
    }

    @Test func contentLeaseEvictionWaitsForEveryHolderAndRejectsReleasedTokens() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive()
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("fixture"))
        let pool = EPUBContentPool(limits: .init(diskBytes: 0, entries: 0))
        let root = f.root.appendingPathComponent("Pool")
        let first = try await pool.acquire(bookID: "a", archive: archive, expected: package, root: root)
        let pin = try await first.lease.duplicate()
        let folder = pin.publication.resourceRoot
        await first.lease.finish(retain: true)
        await first.lease.release() // Repeated/late release cannot consume the renderer's token.
        #expect(FileManager.default.fileExists(atPath: folder.path))
        await #expect(throws: EPUBError.staleSession) { try await first.lease.duplicate() }
        await pool.discardUnused(root: root)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try EPUBPublicationCache.verifyResources(pin.publication)
        await pin.release()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func diskContentSurvivesPoolRecreationAndCancellationPublishesNothing() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive()
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("fixture"))
        let root = f.root.appendingPathComponent("Pool")
        var initial: EPUBContentPool? = EPUBContentPool()
        let prepared = try #require(try await initial?.acquire(bookID: "a", archive: archive, expected: package, root: root))
        let folder = prepared.lease.publication.resourceRoot
        await prepared.lease.finish(retain: true)
        initial = nil // No live tokens. A distinct owner reads disk receipts, not an in-memory package.
        let recreated = EPUBContentPool()
        let restored = try await recreated.acquire(bookID: "a", archive: archive, expected: package, root: root)
        #expect(restored.reused && restored.lease.publication.resourceRoot == folder)
        await restored.lease.release()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await recreated.acquire(bookID: "b", archive: archive, expected: package, root: root)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
        await recreated.discardUnused(root: root)
    }

    @Test func corruptedLeasedVersionIsNotDeletedUntilOldRendererReleasesIt() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive()
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("fixture"))
        let root = f.root.appendingPathComponent("Pool"), pool = EPUBContentPool()
        let old = try await pool.acquire(bookID: "a", archive: archive, expected: package, root: root)
        let pin = try await old.lease.duplicate()
        await old.lease.finish(retain: true)
        let path = pin.publication.resourceRoot.appendingPathComponent("OPS/one.xhtml")
        var bytes = try Data(contentsOf: path); bytes[bytes.startIndex] ^= 1
        try bytes.write(to: path)
        let recovered = try await pool.acquire(bookID: "a", archive: archive, expected: package, root: root)
        #expect(!recovered.reused && recovered.lease.publication.resourceRoot != pin.publication.resourceRoot)
        #expect(FileManager.default.fileExists(atPath: path.path))
        await #expect(throws: EPUBError.staleSession) { try await pin.duplicate() }
        try EPUBPublicationCache.verifyResources(recovered.lease.publication)
        await pin.release()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        await recovered.lease.release()
    }
    @Test func invalidPeerReceiptDoesNotBlockOtherBooks() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive()
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("fixture"))
        let root = f.root.appendingPathComponent("Pool"), pool = EPUBContentPool()
        let corrupt = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 1025).write(to: corrupt.appendingPathComponent("receipt.json"))
        let prepared = try await pool.acquire(bookID: "valid", archive: archive, expected: package, root: root)
        #expect(!prepared.reused && !FileManager.default.fileExists(atPath: corrupt.path))
        try EPUBPublicationCache.verifyResources(prepared.lease.publication)
        await prepared.lease.release()
    }

    @Test func unavailableOptionalCacheFallsBackToTemporaryLeasedContent() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive()
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("fixture"))
        let root = f.root.appendingPathComponent("Pool"), pool = EPUBContentPool()
        let original = Data("not a cache directory".utf8)
        try original.write(to: root)
        let prepared = try await pool.acquire(bookID: "valid", archive: archive, expected: package, root: root)
        let folder = prepared.lease.publication.resourceRoot
        #expect(!prepared.reused && folder.path.contains("/Imports/"))
        try EPUBPublicationCache.verifyResources(prepared.lease.publication)
        await prepared.lease.finish(retain: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try Data(contentsOf: root) == original) // Invalid cache root is not replaced/deleted.
    }
}

private extension EPUBContentPoolTests {
    func verifyMetadataSnapshotReuse() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive(title: "Snapshot A")
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("parsed"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(package)
        let firstByteSnapshot = try EPUBMetadataSnapshot(metadata: bytes)
        #expect(firstByteSnapshot.matches(bytes))
        #expect(throws: (any Error).self) { try EPUBMetadataSnapshot(metadata: Data("invalid".utf8)) }
        let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Snapshot A", with: "Snapshot B").utf8)
        let changedSnapshot = try EPUBMetadataSnapshot(metadata: changed)
        #expect(changed.count == bytes.count && !firstByteSnapshot.matches(changed))
        #expect(changedSnapshot.package.versionID == package.versionID)
        var fingerprints = EPUBMetadataFingerprintCache()
        let first = try fingerprints.resolve(firstByteSnapshot)
        #expect(!first.reused && first.digest == EPUBResourceStore.digest(bytes))
        #expect(try fingerprints.resolve(EPUBMetadataSnapshot(metadata: bytes)).reused)
        let changedResult = try fingerprints.resolve(changedSnapshot)
        #expect(!changedResult.reused && changedResult.digest != first.digest)
        for count in 1...65 {
            let variant = try EPUBMetadataSnapshot(metadata: bytes + Data(repeating: 32, count: count))
            #expect(try fingerprints.resolve(variant).digest == first.digest)
        }
        #expect(fingerprints.count == 64)
        #expect(try fingerprints.resolve(firstByteSnapshot).reused == false)

        // Large synthetic metadata: same scale of chapter count, no private publication content.
        let paths = (0..<1633).map { "OPS/synthetic-\($0).xhtml" }
        let paragraph = String(repeating: "合成正文", count: 25)
        let nodes = Dictionary(uniqueKeysWithValues: paths.map { ($0, Array(repeating: paragraph, count: 32)) })
        let large = EPUBPackage(sourceSHA256: package.sourceSHA256, title: "Large synthetic metadata",
                                spine: paths, navigation: [], resources: [], textNodes: nodes, coverPath: nil)
        let largeSnapshot = try EPUBMetadataSnapshot(metadata: encoder.encode(large))
        var largeCache = EPUBMetadataFingerprintCache()
        #expect(try largeCache.resolve(largeSnapshot).reused == false)
        #expect(try largeCache.resolve(largeSnapshot).reused)
        #expect(largeCache.count == 1)
        let largeReused = try EPUBMetadataSnapshot(metadata: encoder.encode(large), reusing: largeSnapshot.decoded)
        #expect(largeReused.decodeReused && largeReused.decoded === largeSnapshot.decoded)
        #expect(largeReused.package == large)

        let root = f.root.appendingPathComponent("Pool"), pool = EPUBContentPool()
        let snapshot = firstByteSnapshot
        let cold = try await pool.acquire(bookID: package.sourceSHA256, archive: archive, snapshot: snapshot, root: root)
        #expect(!cold.timings.packageFingerprintReused)
        await cold.lease.finish(retain: true)
        let warm = try await pool.acquire(bookID: package.sourceSHA256, archive: archive, snapshot: snapshot, root: root)
        #expect(warm.reused && warm.timings.packageFingerprintReused)
        #expect(warm.timings.samples.contains { $0.phase == .sourceVerification && $0.succeeded })
        #expect(warm.timings.samples.contains { $0.phase == .warmResourceVerification && $0.succeeded })
        let damaged = warm.lease.publication.resourceRoot.appendingPathComponent("OPS/one.xhtml")
        var resource = try Data(contentsOf: damaged); resource[resource.startIndex] ^= 1
        try resource.write(to: damaged)
        let rebuilt = try await pool.acquire(bookID: package.sourceSHA256, archive: archive, snapshot: snapshot, root: root)
        #expect(!rebuilt.reused && rebuilt.timings.packageFingerprintReused)
        #expect(rebuilt.lease.publication.resourceRoot != warm.lease.publication.resourceRoot)
        try EPUBPublicationCache.verifyResources(rebuilt.lease.publication)
        await warm.lease.release(); await rebuilt.lease.finish(retain: true)
        var source = try Data(contentsOf: archive); source[source.startIndex] ^= 1
        try source.write(to: archive)
        await #expect(throws: LibraryError.changedFile) {
            try await pool.acquire(bookID: package.sourceSHA256, archive: archive, snapshot: snapshot, root: root)
        }
        await pool.discardUnused(root: root)
    }

    func verifyMetadataMutationRejectsSession() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive(title: "Snapshot A"))
        let id = receipt.book.id
        let snapshot = try await f.store.storedEPUBSnapshot(bookID: id)
        let permit = try await f.store.reserveReaderOpen(bookID: id)
        let queue = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
        let original = try #require(try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [id])
        })
        let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Snapshot A", with: "Snapshot B").utf8)
        #expect(changed.count == original.count && !snapshot.matches(changed))
        #expect(try EPUBMetadataSnapshot(metadata: changed).package.versionID == snapshot.package.versionID)
        try await queue.write { db in
            try db.execute(sql: "UPDATE epubPackages SET metadata=? WHERE bookID=?", arguments: [changed, id])
        }
        let fresh = try await f.store.storedEPUBSnapshot(bookID: id, reusing: snapshot.decoded)
        #expect(!fresh.decodeReused && fresh.package.title == "Snapshot B")
        await #expect(throws: EPUBError.corruptResource) { try await f.store.beginEPUB(permit, snapshot: snapshot) }
        let active = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT activeSession FROM books WHERE id=?", arguments: [id])
        }
        #expect(active == nil)
        try await queue.write { db in
            try db.execute(sql: "UPDATE epubPackages SET metadata=? WHERE bookID=?", arguments: [original, id])
        }
        let start = try await f.store.beginEPUB(permit, snapshot: snapshot)
        await f.store.endReaderOpen(permit)
        try await f.store.abandonEPUB(session: start.session)
        await #expect(throws: CancellationError.self) { try await f.store.beginEPUB(permit, snapshot: snapshot) }
    }
}

private extension EPUBContentPoolTests {
    func verifySessionBreakdown(_ opening: EPUBOpeningTimings) throws {
        let samples = opening.sessionBreakdown.samples
        #expect(samples.count == EPUBSessionBreakdown.Phase.allCases.count)
        #expect(Set(samples.map { $0.phase.rawValue }) == Set(EPUBSessionBreakdown.Phase.allCases.map { $0.rawValue }))
        #expect(samples.allSatisfy { $0.succeeded && $0.seconds.isFinite && $0.seconds >= 0 })
        #expect(opening.sessionBreakdown.metadataBytes > 0)
        let session = try #require(opening.samples.first { $0.phase == .session })
        let begin = try #require(samples.first { $0.phase == .beginCall })
        let outerTotal = samples.filter { $0.phase.isOuter }.reduce(0) { $0 + $1.seconds }
        let innerTotal = samples.filter { !$0.phase.isOuter }.reduce(0) { $0 + $1.seconds }
        #expect(outerTotal <= session.seconds + 0.000001)
        #expect(innerTotal <= begin.seconds + 0.000001)
        #expect(opening.summary.contains("session-breakdown-v1"))
        #expect(opening.summary.contains("不与外层重复相加"))
        #expect(opening.summary.contains("非纯fsync"))

        let origin = ContinuousClock.now
        var bounded = EPUBSessionBreakdown()
        bounded.record(.beginCall, since: origin, until: origin.advanced(by: .milliseconds(12)))
        #expect(abs(try #require(bounded.samples.first).seconds - 0.012) < 0.000001)
        var nested = EPUBSessionBreakdown()
        nested.metadataBytes = 321
        nested.record(.metadataRead, since: origin, until: origin.advanced(by: .milliseconds(3)))
        bounded.merge(nested)
        #expect(bounded.metadataBytes == 321 && bounded.samples.count == 2)
        for _ in 0..<64 { bounded.record(.bookRead, since: origin, until: origin) }
        bounded.merge(nested)
        #expect(bounded.samples.count == 24)
        #expect(EPUBSessionBreakdown().summary.isEmpty)

        enum ProbeFailure: Error { case expected }
        var failed = EPUBSessionBreakdown()
        #expect(throws: ProbeFailure.expected) {
            try failed.measure(.metadataRead) { throw ProbeFailure.expected }
        }
        #expect(failed.samples.count == 1 && failed.samples.first?.succeeded == false)
        var successful = EPUBSessionBreakdown()
        #expect(successful.measure(.rowUpdate) { 42 } == 42)
        #expect(successful.samples.count == 1 && successful.samples.first?.succeeded == true)
    }
}

private extension EPUBContentPoolTests {
    func verifyLeaseHeldMetadataReuse() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let archive = try f.archive(title: "Decoded A")
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: f.root.appendingPathComponent("parsed"))
        let bytes = try JSONEncoder().encode(package)
        let original = try EPUBMetadataSnapshot(metadata: bytes)
        let pool = EPUBContentPool(), root = f.root.appendingPathComponent("Pool")
        let before = await pool.reusableMetadata(bookID: package.sourceSHA256, root: root)
        #expect(before == nil)
        let first = try await pool.acquire(bookID: package.sourceSHA256, archive: archive, snapshot: original, root: root)
        let pin = try await first.lease.duplicate()
        await first.lease.finish(retain: true)
        let borrowed = try #require(await pool.reusableMetadata(bookID: package.sourceSHA256, root: root))
        let same = try EPUBMetadataSnapshot(metadata: bytes, reusing: borrowed)
        #expect(same.decodeReused && same.decoded === original.decoded)
        #expect(same.matches(bytes) && same.package == package)
        let foreignRoot = await pool.reusableMetadata(bookID: package.sourceSHA256, root: f.root)
        let foreignBook = await pool.reusableMetadata(bookID: "foreign", root: root)
        #expect(foreignRoot == nil && foreignBook == nil)
        let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Decoded A", with: "Decoded B").utf8)
        let changedSnapshot = try EPUBMetadataSnapshot(metadata: changed, reusing: borrowed)
        #expect(changed.count == bytes.count && changedSnapshot.decodeReused == false)
        #expect(changedSnapshot.package.versionID == package.versionID && changedSnapshot.package.title == "Decoded B")
        #expect(changedSnapshot.decoded !== original.decoded && !same.matches(changed))
        #expect(throws: (any Error).self) { try EPUBMetadataSnapshot(metadata: Data("invalid".utf8), reusing: borrowed) }
        let reopened = try await pool.acquire(bookID: package.sourceSHA256, archive: archive, snapshot: same, root: root)
        #expect(reopened.reused)
        await reopened.lease.release()
        let pinned = await pool.reusableMetadata(bookID: package.sourceSHA256, root: root)
        #expect(pinned === original.decoded)
        await pin.release()
        let afterRelease = await pool.reusableMetadata(bookID: package.sourceSHA256, root: root)
        #expect(afterRelease == nil) // Retained disk receipt does not retain a decoded tree.
        let coldAgain = try EPUBMetadataSnapshot(metadata: bytes, reusing: afterRelease)
        #expect(!coldAgain.decodeReused)
        await pool.discardUnused(root: root)
    }

    func verifyResourceAttributes() throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let files = FileManager.default, root = f.root.appendingPathComponent("attribute-fixture")
        let parent = root.appendingPathComponent("OPS"), leaf = parent.appendingPathComponent("one.xhtml")
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let bytes = Data("synthetic resource".utf8)
        let resource = EPUBResource(path: "OPS/one.xhtml", mediaType: "application/xhtml+xml",
                                    sha256: EPUBResourceStore.digest(bytes), byteCount: bytes.count)
        try bytes.write(to: leaf)
        #expect(try EPUBResourceStore.data(resource: resource, root: root) == bytes)
        let flat = root.appendingPathComponent("flat.xhtml")
        try bytes.write(to: flat)
        let flatResource = EPUBResource(path: "flat.xhtml", mediaType: resource.mediaType,
                                        sha256: resource.sha256, byteCount: resource.byteCount)
        #expect(try EPUBResourceStore.data(resource: flatResource, root: root) == bytes)
        var damaged = bytes; damaged[damaged.startIndex] ^= 1
        try damaged.write(to: leaf)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(resource: resource, root: root) }
        try (bytes + Data([0])).write(to: leaf)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(resource: resource, root: root) }
        try files.removeItem(at: leaf)
        try files.createSymbolicLink(at: leaf, withDestinationURL: flat)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(resource: resource, root: root) }
        try files.removeItem(at: leaf)
        try files.createDirectory(at: leaf, withIntermediateDirectories: false)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(resource: resource, root: root) }
        try files.removeItem(at: leaf)
        try bytes.write(to: leaf)
        let moved = root.appendingPathComponent("real-OPS")
        try files.moveItem(at: parent, to: moved)
        try files.createSymbolicLink(at: parent, withDestinationURL: moved)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(resource: resource, root: root) }
        let rootLink = f.root.appendingPathComponent("root-link")
        try files.createSymbolicLink(at: rootLink, withDestinationURL: root)
        #expect(throws: EPUBError.corruptResource) { try EPUBResourceStore.data(resource: flatResource, root: rootLink) }
    }
}
