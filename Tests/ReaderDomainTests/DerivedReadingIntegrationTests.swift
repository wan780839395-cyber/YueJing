import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct DerivedReadingIntegrationTests {
    @Test func productImportReusesItsDocumentEvenWhenTheLegacyMemoryCacheIsDisabled() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let service = LibraryService(store: f.store, processingCacheLimit: 0)
        let receipt = try await importForReader("Chapter 1\r\n" + String(repeating: "synthetic text\n", count: 2500),
                                                fixture: f, service: service, budget: f.budget)
        let stats = await service.readingRouteStatistics(), legacy = await service.processingReuseStatistics()
        #expect(stats.importedDocumentReuses == 1 && stats.documentDecodes == 0 && stats.chapterBuilds == 1)
        #expect(legacy.decodeCalls == 1 && legacy.retainedBytes == 0)
        let reader = try await service.openReader(id: receipt.book.id, budget: f.budget)
        #expect(reader.cacheDisposition == .diskHit)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await reader.chapterPage(start: 0, limit: f.budget.maximumChapterEntries + 1) }
        try await reader.close()
    }
    @Test func aNewServiceReusesDiskWithFreshSessionsLatestSettingsAndPosition() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let anchor = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let settings = ReaderPreferences(fontSize: 28, lineSpacing: 11, theme: .dark)
        try await f.store.savePreferences(settings)
        let fresh = LibraryService(store: f.store)
        let first = try await fresh.openReader(id: f.book.id, budget: f.budget)
        #expect(first.reading.anchor == anchor && first.preferences == settings)
        try await first.close()
        let second = try await fresh.openReader(id: f.book.id, budget: f.budget)
        #expect(second.reading.session.id != first.reading.session.id && second.reading.anchor == anchor)
        let stats = await fresh.readingRouteStatistics()
        #expect(stats.diskHits == 2 && stats.documentDecodes == 0 && stats.chapterBuilds == 0)
        #expect(await f.store.activeDerivedLeaseCount() == 1)
        try await second.close(); #expect(await f.store.activeDerivedLeaseCount() == 0)
        // A new service in this process is not real App process-restart evidence.
    }
    @Test func aLegacyBookMigratesOnceAndTheProductPathDropsTheLegacyFullDocumentCache() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        _ = try await f.service.openBook(id: f.book.id)
        #expect(await f.service.processingReuseStatistics().retainedBytes > 0)
        let first = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(first.cacheDisposition == .rebuilt)
        #expect(await f.service.processingReuseStatistics().retainedBytes == 0)
        try await first.close()
        let second = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let stats = await f.service.readingRouteStatistics()
        #expect(second.cacheDisposition == .diskHit && stats.documentDecodes == 1 && stats.chapterBuilds == 1)
        try await second.close()
    }
    @Test func boundedWindowsMatchTheOriginalEngineAcrossPagesChaptersAndSettings() async throws {
        let text = "第一章 起点\r\n" + String(repeating: "中😀e\u{301}，正文🇨🇳\r\n", count: 6000) + "第二章 终点\r\n末尾"
        let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let reference = ReadingLayoutEngine(bookID: f.book.id, document: f.document)
        let boundaries = f.document.offsets.boundaries
        for index in [0, boundaries.count / 2, boundaries.count - 5] {
            let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: boundaries[index].rawByte.value, lineFraction: 0.4)
            for width in [280.0, 650.0] {
                for font in [16.0, 30.0] {
                    let settings = ReaderPreferences(fontSize: font, lineSpacing: 9, theme: .dark)
                    let old = try await reference.window(around: anchor, width: width, preferences: settings)
                    let actual = try await reader.window(around: anchor, width: width, preferences: settings)
                    #expect(actual.anchor == anchor && actual.targetUTF16 == old.targetUTF16)
                    #expect(actual.slices.map(\.range) == old.slices.map(\.range) && actual.slices.count <= 7)
                    let left = old.slices.flatMap(\.lines), right = actual.slices.flatMap(\.lines)
                    #expect(left.map(\.range) == right.map(\.range) && left.map(\.rawByteStart) == right.map(\.rawByteStart))
                    #expect(left.map { Data($0.text.utf8) } == right.map { Data($0.text.utf8) })
                    #expect(zip(left, right).allSatisfy { pair in abs(pair.0.height - pair.1.height) < 0.001 })
                }
            }
        }
        #expect(await reader.source.statistics().retainedLogicalBytes <= f.budget.maximumWorkingBytes)
        try await reader.close()
    }
    @Test func directoryPagesAndChapterJumpsUseStableGlobalCoordinates() async throws {
        let text = (1...85).map { "Chapter \($0)\r\n正文😀e\u{301}\r\n" }.joined()
        let f = try await DerivedBookFixture(bytes: Data(text.utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        var ids: [String] = []
        #expect(f.chapters.count == 85 && reader.source.metadata.chapterCount == 85)
        for start in stride(from: 0, to: f.chapters.count, by: 32) {
            let page = try await reader.chapterPage(start: start, limit: 32)
            #expect(page.count <= 32); ids += page.map(\.id)
            let chapter = try #require(page.last)
            let anchor = ReadingAnchor(bookID: f.book.id, versionID: chapter.documentVersion, rawByteOffset: chapter.rawByteRange.location.value)
            let window = try await reader.window(around: anchor, width: 320, preferences: reader.preferences)
            #expect(window.targetUTF16 == chapter.utf16Range.location.value && window.anchor == anchor)
        }
        #expect(ids == f.chapters.map(\.id)); try await reader.close()
    }
    @Test func aPathologicalClusterKeepsTheOldLayoutFailureAndDoesNotWriteAFakeStart() async throws {
        let f = try await DerivedBookFixture(bytes: Data(("a" + String(repeating: "\u{301}", count: 20000)).utf8)); defer { f.remove() }
        let saved = try await f.savedAnchor(), reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let reference = ReadingLayoutEngine(bookID: f.book.id, document: f.document)
        await #expect(throws: LibraryError.layoutCannotAdvance) { try await reference.window(around: saved, width: 320, preferences: reader.preferences) }
        await #expect(throws: LibraryError.layoutCannotAdvance) { try await reader.window(around: saved, width: 320, preferences: reader.preferences) }
        try await reader.close()
        #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == saved)
    }
    @Test func aCachedProductOpenStillRejectsChangedAndMissingOriginals() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let saved = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let url = try await f.store.fileURL(bookID: f.book.id)
        var changed = f.document.originalBytes; changed[changed.count / 2] ^= 1
        try changed.write(to: url, options: .atomic)
        await #expect(throws: LibraryError.changedFile) { try await f.service.openReader(id: f.book.id, budget: f.budget) }
        try FileManager.default.removeItem(at: url)
        await #expect(throws: LibraryError.missingFile) { try await f.service.openReader(id: f.book.id, budget: f.budget) }
        #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == saved)
        #expect(await f.service.readingRouteStatistics().documentDecodes == 1) // Only the initial explicit construction.
    }
    @Test func corruptPagesCloseTheirLeaseAndAnExplicitNewOpenRebuildsWithoutLosingProgress() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let saved = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        try await f.changeByte(section: 0); await reader.releasePageCache()
        await #expect(throws: DerivedStorageError.corruptArtifact) { try await reader.window(around: saved, width: 320, preferences: reader.preferences) }
        try await reader.close()
        #expect(await f.store.activeDerivedLeaseCount() == 0)
        let recovered = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(recovered.cacheDisposition == .rebuilt && recovered.reading.anchor == saved)
        _ = try await recovered.window(around: saved, width: 320, preferences: recovered.preferences)
        try await recovered.close()
    }
    @Test func derivedAdmissionFailureLeavesImportedTruthAndReliableProgressIntact() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let tiny = try DerivedBookFixture.limits(artifact: 4096)
        let receipt = try await importForReader("Chapter 1\nnew committed text\n", fixture: f, service: f.service, budget: tiny)
        let saved = try await saveReaderAnchor(store: f.store, book: receipt.book, raw: 3)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await f.service.openReader(id: receipt.book.id, budget: tiny) }
        #expect(try await f.store.book(id: receipt.book.id)?.versionID == receipt.book.versionID)
        #expect(try await f.store.beginReading(bookID: receipt.book.id, versionID: receipt.book.versionID).anchor == saved)
        #expect(await f.service.processingReuseStatistics().retainedBytes == 0)
        #expect(await f.store.activeDerivedLeaseCount() == 0)
    }
    @Test func cancellationAfterOriginalCommitStillReturnsTheCommittedImport() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let task = Task {
            try await importForReader("Chapter 1\nlate cancel text\n", fixture: f, service: f.service, budget: f.budget,
                observe: { if $0 == .committed { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        let receipt = try await task.value
        #expect(try await f.store.book(id: receipt.book.id)?.id == receipt.book.id)
        let reader = try await f.service.openReader(id: receipt.book.id, budget: f.budget)
        try await reader.close()
    }
    @Test func memoryPressureDropsOnlyPagesAndKeepsTheActiveSessionUsable() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: reader.source.metadata.bomByteCount)
        _ = try await reader.window(around: anchor, width: 320, preferences: reader.preferences)
        let before = await reader.source.statistics()
        await f.service.releaseProcessingCache(); await reader.releasePageCache()
        let after = await reader.source.statistics()
        #expect(after.retainedLogicalBytes < before.retainedLogicalBytes)
        #expect(await f.store.activeDerivedLeaseCount() == 1)
        _ = try await reader.window(around: anchor, width: 320, preferences: reader.preferences)
        try await reader.close()
    }
    @Test func productCacheReclaimsUnleasedOldPackagesButNeverTheActiveLeaseOrOriginalProgress() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let saved = try await f.savedAnchor()
        try await f.service.buildDerivedBook(id: f.book.id, budget: f.budget)
        let (oldURL, pointer) = try await f.artifact()
        let source = f.root.appendingPathComponent("next.txt"); try Data("Chapter 1\nnext book\n".utf8).write(to: source)
        guard case .completed(let next) = try await f.service.prepareImport(url: source, ticket: UUID()) else { Issue.record("Expected import"); return }
        let budget = try DerivedBookBudget(maximumArtifactBytes: 4 * 1024 * 1024,
            maximumStoredBytes: 4 * 1024 * 1024 + pointer.byteCount - 1, maximumMetadataBytes: 256 * 1024,
            maximumWorkingBytes: 4 * 1024 * 1024, maximumReadUTF16: 8192, maximumChapterEntries: 32)
        let active = try await f.service.openReader(id: f.book.id, budget: f.budget)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await f.service.openReader(id: next.book.id, budget: budget) }
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        try await active.close()
        let opened = try await f.service.openReader(id: next.book.id, budget: budget)
        #expect(FileManager.default.fileExists(atPath: oldURL.path) == false)
        #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == saved)
        #expect(try Data(contentsOf: await f.store.fileURL(bookID: f.book.id)) == f.document.originalBytes)
        try await opened.close()
    }
    @Test func navigationRejectsOldWindowCallbacksUntilTheExactTargetWindowIsApplied() throws {
        var gate = ReadingNavigationGate(); let old = UUID(), target = UUID()
        gate.applied(window: old); #expect(gate.accepts(window: old))
        gate.begin(); let token = try #require(gate.navigation)
        #expect(gate.accepts(window: old) == false)
        gate.applied(window: old); #expect(gate.navigation == token && gate.isDisplayed(window: old))
        gate.expect(window: target, navigation: token); #expect(gate.accepts(window: old) == false)
        let didApply = gate.applied(window: target)
        #expect(didApply); #expect(gate.accepts(window: target))
        #expect(gate.accepts(window: old) == false)
        gate.begin(); let newer = try #require(gate.navigation)
        gate.expect(window: old, navigation: token); gate.applied(window: old)
        #expect(gate.navigation == newer)
    }
}
