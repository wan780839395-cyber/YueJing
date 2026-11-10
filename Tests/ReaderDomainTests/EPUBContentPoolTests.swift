import Foundation
import Testing
@testable import ReaderDomain

struct EPUBContentPoolTests {
    @Test func recentBooksReuseIndependentVersionsWithoutCopying() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let a = try await f.install(f.archive(title: "Recent A"))
        let b = try await f.install(f.archive(title: "Recent B"))
        let first = try await f.service.openEPUB(id: a.book.id)
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
        await pin.release()
        try EPUBPublicationCache.verifyResources(reopened.publication)
        try await reopened.abandon()
        let cacheRoot = await f.store.epubContentPoolURL()
        await EPUBContentPool.shared.discardUnused(root: cacheRoot)
        #expect(!FileManager.default.fileExists(atPath: aRoot.path))
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
