import Foundation
import GRDB
import Testing
import TXTCore
@testable import ReaderDomain

struct DerivedBookPublicationTests {
    @Test func v2DatabaseUpgradePreservesExistingBookVersionAndProgressAndEnablesDerivedPointers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-derived-v2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Books"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Imports"), withIntermediateDirectories: false)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path)
        try LibrarySchema.migrator().migrate(queue, upTo: "v2-reading-state")
        let absent = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='derivedArtifacts'")
        }
        #expect(absent == nil)
        let bytes = Data("第一章 起点\r\n迁移合成😀正文\r\n".utf8)
        let document = try await TXTProcessor().decode(bytes, using: .utf8)
        let book = LibraryBook(id: document.documentID, title: "v2合成迁移", encodingRaw: TXTEncoding.utf8.rawValue,
            versionID: document.versionID, byteCount: bytes.count, utf16Count: document.utf16Count)
        let raw = try document.offsets.rawByteOffset(for: UTF16Offset(1)).value
        let anchor = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: raw, lineFraction: 0.25)
        let original = root.appendingPathComponent("Books").appendingPathComponent(book.id + ".txt")
        try bytes.write(to: original)
        try await queue.write { db in
            try book.insert(db)
            try db.execute(sql: "INSERT INTO progress(bookID,versionID,unit,rawByteOffset,lineFraction,sessionID,sequence) VALUES (?, ?, 'raw-byte-v1', ?, 0.25, 'previous-session', 4)",
                           arguments: [book.id, book.versionID, raw])
        }
        let upgraded = try LibraryStore(root: root)
        #expect(try await upgraded.book(id: book.id)?.versionID == book.versionID)
        #expect(try await upgraded.books().count == 1)
        #expect(try await upgraded.beginReading(bookID: book.id, versionID: book.versionID).anchor == anchor)
        let before = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derivedArtifacts") }
        #expect(before == 0)
        let service = LibraryService(store: upgraded), budget = try DerivedBookFixture.limits()
        try await service.buildDerivedBook(id: book.id, budget: budget)
        let source = try await service.openDerivedBook(id: book.id, budget: budget)
        #expect(try await source.utf16Offset(for: RawByteOffset(raw)) == UTF16Offset(1)); await source.close()
        let after = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derivedArtifacts") }
        #expect(after == 1)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try await upgraded.beginReading(bookID: book.id, versionID: book.versionID).anchor == anchor)
    }
    @Test func existingDefaultImportAndReaderDoNotCreateDerivedPackages() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let original = f.root.appendingPathComponent("synthetic.txt"), bytes = Data("new ascii book\r\nsecond line\n".utf8)
        try bytes.write(to: original)
        guard case .completed(let receipt) = try await f.service.prepareImport(url: original, ticket: UUID()) else {
            Issue.record("Expected the original import path"); return
        }
        let opened = try await f.service.openBook(id: receipt.book.id)
        #expect(opened.document.text == "new ascii book\nsecond line\n")
        #expect(FileManager.default.fileExists(atPath: f.managed.appendingPathComponent("Derived").path) == false)
        #expect(try Data(contentsOf: original) == bytes)
    }
    @Test func diskReopenWithNewStoreKeepsVersionAndSavedProgressWithoutAFullDocumentAPI() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let anchor = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        // This exercises persisted state reload, NOT a real process restart measurement.
        let freshStore = try LibraryStore(root: f.managed), freshService = LibraryService(store: freshStore)
        let source = try await freshService.openDerivedBook(id: f.book.id, budget: f.budget)
        #expect(source.metadata.versionID == f.book.versionID)
        #expect(try await source.utf16Offset(for: RawByteOffset(anchor.rawByteOffset)).value == 0)
        #expect(try await freshStore.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == anchor)
        let stats = await freshService.processingReuseStatistics()
        #expect(stats.decodeCalls == 0 && stats.chapterCalls == 0 && stats.retainedBytes == 0)
        await source.close()
    }
    @Test func completeSourceSHARejectsSameSizeChangesAtBeginningMiddleEndAndMissingOriginal() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let original = f.document.originalBytes, url = try await f.store.fileURL(bookID: f.book.id)
        let anchor = try await f.savedAnchor()
        for offset in [0, original.count / 2, original.count - 1] {
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            var changed = original; changed[offset] ^= 1; try changed.write(to: url, options: .atomic)
            await #expect(throws: LibraryError.changedFile) { try await f.service.openDerivedBook(id: f.book.id, budget: f.budget, rebuildIfNeeded: true) }
            try original.write(to: url, options: .atomic)
        }
        for changed in [original + Data([65]), Data(original.dropLast())] {
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
            try changed.write(to: url, options: .atomic)
            await #expect(throws: LibraryError.changedFile) { try await f.service.openDerivedBook(id: f.book.id, budget: f.budget, rebuildIfNeeded: true) }
            await #expect(throws: LibraryError.changedFile) { try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget) }
            try original.write(to: url, options: .atomic)
        }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        try FileManager.default.removeItem(at: url)
        await #expect(throws: LibraryError.missingFile) { try await f.service.openDerivedBook(id: f.book.id, budget: f.budget, rebuildIfNeeded: true) }
        #expect(try await f.store.book(id: f.book.id)?.versionID == f.book.versionID)
        #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == anchor)
    }
    @Test func wrongStoredVersionNeverRewritesBookOrProgressToMatchANewPackage() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let anchor = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let queue = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
        let wrong = String(repeating: "f", count: 64), id = f.book.id
        try await queue.write { db in try db.execute(sql: "UPDATE books SET versionID = ? WHERE id = ?", arguments: [wrong, id]) }
        await #expect(throws: DerivedStorageError.versionMismatch) { try await f.service.openDerivedBook(id: id, budget: f.budget, rebuildIfNeeded: true) }
        #expect(try await f.store.book(id: id)?.versionID == wrong)
        let saved = try await queue.read { db in try String.fetchOne(db, sql: "SELECT versionID FROM progress WHERE bookID = ?", arguments: [id]) }
        #expect(saved == anchor.versionID)
    }
    @Test func writeSpaceAndPublicationFaultsPreserveThePreviouslyCommittedGeneration() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let anchor = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let (_, previous) = try await f.artifact()
        for target in [DerivedBuildStep.staged, .payloadWritten, .synchronized, .beforePublish, .renamed] {
            await #expect(throws: POSIXError.self) {
                try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget, inject: { step in
                    if step == target { throw POSIXError(.ENOSPC) }
                })
            }
            #expect(try await f.artifact().1 == previous)
            try await f.store.recoverDerivedStorage()
            let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget); await source.close()
        }
        #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == anchor)
        #expect(try Data(contentsOf: await f.store.fileURL(bookID: f.book.id)) == f.document.originalBytes)
    }
    @Test func cancellationBeforePublishAbortsButAfterCommitReturnsCommittedTruth() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let (_, previous) = try await f.artifact()
        let before = Task {
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget, inject: { step in
                if step == .beforePublish { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await before.value }
        #expect(try await f.artifact().1 == previous)
        let after = Task {
            try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget, inject: { step in
                if step == .published { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        #expect(try await after.value.versionID == f.book.versionID)
        #expect(try await f.artifact().1.generation != previous.generation)
    }
    @Test func staleCASCannotOverwriteOrInvalidateNewPointerAndLeasesProtectOldReaders() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let (oldURL, oldPointer) = try await f.artifact()
        let oldReader = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget)
        let storage = DerivedBookStorage()
        let older = try await f.store.reserveDerived(bookID: f.book.id, budget: f.budget)
        let oldStageURL = try await f.store.derivedStagingURL(older)
        let oldStage = try await storage.stage(document: f.document, chapters: f.chapters, permit: older,
            url: oldStageURL, budget: f.budget, inject: nil)
        let newer = try await f.store.reserveDerived(bookID: f.book.id, budget: f.budget)
        let newStageURL = try await f.store.derivedStagingURL(newer)
        let newStage = try await storage.stage(document: f.document, chapters: f.chapters, permit: newer,
            url: newStageURL, budget: f.budget, inject: nil)
        let current = try await f.store.publishDerived(newStage, permit: newer, inject: nil)
        await #expect(throws: DerivedStorageError.staleBuild) { try await f.store.publishDerived(oldStage, permit: older, inject: nil) }
        await f.store.abandonDerived(older); try await f.store.invalidateDerived(oldPointer)
        #expect(try await f.artifact().1 == current)
        try await f.store.recoverDerivedStorage()
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try await oldReader.text(in: UTF16Range(location: UTF16Offset(0), length: 2)).text == "第一")
        let damaged = try FileHandle(forUpdating: oldURL)
        let byte = try DerivedBookFormat.read(damaged, offset: 4096, count: 1, maximumBytes: 1)
        try damaged.seek(toOffset: 4096); try damaged.write(contentsOf: Data([byte[0] ^ 1])); try damaged.close()
        await oldReader.releasePageCache()
        await #expect(throws: DerivedStorageError.corruptArtifact) { try await oldReader.text(in: UTF16Range(location: UTF16Offset(0), length: 2)) }
        #expect(try await f.artifact().1 == current)
        await oldReader.close(); try await f.store.recoverDerivedStorage()
        #expect(FileManager.default.fileExists(atPath: oldURL.path) == false)
        #expect(try await f.artifact().1 == current)
    }
    @Test func concurrentExplicitBuildersLeaveOneUsableCurrentGeneration() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let first = Task { () async throws -> Bool in
            do { try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget); return true }
            catch DerivedStorageError.staleBuild { return false }
        }
        let second = Task { () async throws -> Bool in
            do { try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget); return true }
            catch DerivedStorageError.staleBuild { return false }
        }
        let a = try await first.value, b = try await second.value
        #expect(a || b)
        let source = try await f.service.openDerivedBook(id: f.book.id, budget: f.budget)
        #expect(source.metadata.versionID == f.book.versionID); await source.close()
        try await f.store.recoverDerivedStorage()
    }
    @Test func recoveryRemovesRecognizedInterruptedArtifactsAndHandlesCacheLossWithoutDeletingUserState() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let anchor = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let (currentURL, _) = try await f.artifact(), storage = DerivedBookStorage()
        let one = try await f.store.reserveDerived(bookID: f.book.id, budget: f.budget)
        let stageOne = try await f.store.derivedStagingURL(one)
        _ = try await storage.stage(document: f.document, chapters: f.chapters, permit: one, url: stageOne, budget: f.budget, inject: nil)
        let two = try await f.store.reserveDerived(bookID: f.book.id, budget: f.budget)
        let stageTwo = try await f.store.derivedStagingURL(two)
        _ = try await storage.stage(document: f.document, chapters: f.chapters, permit: two, url: stageTwo, budget: f.budget, inject: nil)
        let orphan = stageTwo.deletingPathExtension().appendingPathExtension("pack")
        try FileManager.default.moveItem(at: stageTwo, to: orphan)
        let unknown = f.managed.appendingPathComponent("Derived/keep-me.bin")
        try Data([1, 2, 3]).write(to: unknown)
        // All writers above have stopped. A fresh authority simulates lost in-memory reservations.
        let freshStore = try LibraryStore(root: f.managed), freshService = LibraryService(store: freshStore)
        try await freshStore.recoverDerivedStorage()
        #expect(FileManager.default.fileExists(atPath: stageOne.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(try Data(contentsOf: unknown) == Data([1, 2, 3]))
        try FileManager.default.removeItem(at: currentURL)
        try await freshStore.recoverDerivedStorage()
        let source = try await freshService.openDerivedBook(id: f.book.id, budget: f.budget, rebuildIfNeeded: true)
        await source.close()
        #expect(try await freshStore.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == anchor)
        #expect(try Data(contentsOf: await freshStore.fileURL(bookID: f.book.id)) == f.document.originalBytes)
    }
    @Test func artifactAndAggregateAdmissionBudgetsNeverEvictTheValidBookOrPointer() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let (_, original) = try await f.artifact()
        let tiny = try DerivedBookFixture.limits(artifact: 4096)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await f.service.buildDerivedBook(id: f.book.id, budget: tiny) }
        let aggregate = try DerivedBookBudget(maximumArtifactBytes: 1024 * 1024, maximumStoredBytes: 1024 * 1024,
            maximumMetadataBytes: 256 * 1024, maximumWorkingBytes: 4 * 1024 * 1024,
            maximumReadUTF16: 8192, maximumChapterEntries: 4)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await f.service.buildDerivedBook(id: f.book.id, budget: aggregate) }
        #expect(try await f.artifact().1 == original)
        #expect(try await f.store.books().count == 1)
    }
}
