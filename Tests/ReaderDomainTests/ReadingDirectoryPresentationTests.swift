import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

private func directoryChapter(_ index: Int, version: String = "version", rawLength: Int = 10) throws -> TXTChapter {
    TXTChapter(id: "\(version):\(index * 10)", documentVersion: version, title: "Chapter \(index + 1)",
        utf16Range: try UTF16Range(location: UTF16Offset(index * 10), length: rawLength),
        rawByteRange: try RawByteRange(location: RawByteOffset(index * 10), length: rawLength))
}

private actor DirectoryFixtureLoader {
    let total: Int
    private var requests: [(Int, Int)] = []
    init(_ total: Int) { self.total = total }
    func load(_ start: Int, _ limit: Int) throws -> [TXTChapter] {
        requests.append((start, limit))
        return try (start..<min(total, start + limit)).map { try directoryChapter($0) }
    }
    func observed() -> [(Int, Int)] { requests }
}

private func directoryAnchor(_ raw: Int, version: String = "version") -> ReadingAnchor {
    ReadingAnchor(bookID: "book", versionID: version, rawByteOffset: raw)
}

private func directoryRequestID(_ target: DirectoryRequest, state: inout DirectoryPresentation) throws -> UUID {
    let id = state.begin(target)
    return try #require(id)
}

struct ReadingDirectoryPresentationTests {
    @Test func actualOpenedReaderLocatesBOMChapterPagesAndEOFWithoutMovingSavedProgress() async throws {
        let text = (1...97).map { "Chapter \($0)\n正文😀\n" }.joined()
        let f = try await DerivedBookFixture(bytes: Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8))
        defer { f.remove() }
        let saved = try await f.savedAnchor()
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(f.chapters.count == 97)
        for index in [0, 31, 32, 63, 64, 96] {
            let chapter = f.chapters[index]
            let anchor = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID,
                                       rawByteOffset: chapter.rawByteRange.location.value)
            let page = try await reader.directory(around: anchor)
            #expect(page.currentIndex == index && page.start == index / 32 * 32)
            #expect(page.chapters.count <= 32 && page.chapters[index - page.start].id == chapter.id)
        }
        let eof = ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: f.book.byteCount)
        let last = try await reader.directory(around: eof)
        #expect(last.currentIndex == 96 && last.chapters.count == 1)
        let firstPage = try await reader.directoryPage(start: 0, currentIndex: last.currentIndex)
        #expect(firstPage.start == 0 && firstPage.currentIndex == 96 && firstPage.chapters.count == 32)
        try await reader.close()
        #expect(await f.store.activeDerivedLeaseCount() == 0)
        #expect(try await f.store.beginReading(bookID: f.book.id, versionID: f.book.versionID).anchor == saved)
    }
    @Test func veryLargeDirectoryOnlyUsesLogarithmicProbesAndOneBoundedPage() async throws {
        let fixture = DirectoryFixtureLoader(1_000_000)
        let page = try await ReadingDirectory.locate(anchor: directoryAnchor(999_997 * 10 + 3),
            chapterCount: 1_000_000, byteCount: 10_000_000, load: { try await fixture.load($0, $1) })
        let requests = await fixture.observed()
        #expect(page.currentIndex == 999_997 && page.start == 999_997 / 32 * 32)
        #expect(page.chapters.count <= 32 && requests.count <= 22)
        #expect(requests.allSatisfy { $0.1 <= 32 } && requests.dropLast().allSatisfy { $0.1 == 1 })
    }
    @Test func exactBoundariesLastPageAndEmptyDirectoryHaveExplicitSemantics() async throws {
        for count in [1, 31, 32, 33, 64, 65] {
            let fixture = DirectoryFixtureLoader(count)
            for raw in [0, (count - 1) * 10, count * 10] {
                let page = try await ReadingDirectory.locate(anchor: directoryAnchor(raw), chapterCount: count,
                    byteCount: count * 10, load: { try await fixture.load($0, $1) })
                let expected = min(count - 1, raw / 10)
                #expect(page.currentIndex == expected && page.start == expected / 32 * 32)
            }
        }
        let emptyLoader = DirectoryFixtureLoader(0)
        let empty = try await ReadingDirectory.locate(anchor: directoryAnchor(0), chapterCount: 0, byteCount: 0,
            load: { try await emptyLoader.load($0, $1) })
        #expect(empty.chapters.isEmpty && empty.currentIndex == nil && empty.start == 0)
        #expect(await emptyLoader.observed().isEmpty)
        for raw in [-1, 11] {
            await #expect(throws: ReadingDirectoryError.invalidRequest) {
                try await ReadingDirectory.locate(anchor: directoryAnchor(raw), chapterCount: 1,
                    byteCount: 10, load: { try await emptyLoader.load($0, $1) })
            }
        }
    }
    @Test func emptyTruncatedWrongVersionAndZeroLengthMetadataAreRejectedWithoutSearchingForHoles() async throws {
        await #expect(throws: ReadingDirectoryError.incompleteMetadata) {
            try await ReadingDirectory.locate(anchor: directoryAnchor(0), chapterCount: 5, byteCount: 50, load: { _, _ in [] })
        }
        let zero = try directoryChapter(0, rawLength: 0)
        await #expect(throws: ReadingDirectoryError.incompleteMetadata) {
            try await ReadingDirectory.locate(anchor: directoryAnchor(0), chapterCount: 1, byteCount: 0, load: { _, _ in [zero] })
        }
        let wrong = try directoryChapter(0, version: "old")
        await #expect(throws: ReadingDirectoryError.incompleteMetadata) {
            try await ReadingDirectory.locate(anchor: directoryAnchor(0), chapterCount: 1, byteCount: 10, load: { _, _ in [wrong] })
        }
        let valid = try directoryChapter(0)
        await #expect(throws: ReadingDirectoryError.incompleteMetadata) {
            try await ReadingDirectory.page(start: 0, total: 2, currentIndex: 0, documentVersion: "version", load: { _, _ in [valid] })
        }
    }
    @Test func cancellationAfterAProbeDoesNotContinueToReadOrProduceAPage() async throws {
        let gate = ReaderTestGate(), fixture = DirectoryFixtureLoader(100)
        let task = Task {
            try await ReadingDirectory.locate(anchor: directoryAnchor(500), chapterCount: 100, byteCount: 1000,
                load: { start, count in
                    let value = try await fixture.load(start, count)
                    await gate.pause()
                    return value
                })
        }
        do { try await gate.wait() } catch { task.cancel(); await gate.release(); _ = try? await task.value; throw error }
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.observed().count == 1)
    }
    @Test func queuedCurrentRequestCannotRestartAfterNewPagingOrReplacementOwnerIntent() throws {
        var state = DirectoryPresentation()
        let oldSheet = UUID(), newSheet = UUID()
        state.present(oldSheet)
        let old = try directoryRequestID(.current(directoryAnchor(0)), state: &state)
        let new = try directoryRequestID(.page(32), state: &state)
        #expect(state.requestID != old && state.requestID == new) // The production pre-Task guard.
        let value = ReadingDirectoryPage(start: 32, total: 65, currentIndex: 0, chapters: [try directoryChapter(32)])
        let lateSuccess = state.apply(value, request: old), lateFailure = state.fail("old", request: old)
        #expect(!lateSuccess && !lateFailure && state.loading && state.requestID == new)
        let applied = state.apply(value, request: new)
        #expect(applied && state.page?.start == 32)
        state = DirectoryPresentation() // attach resets the value gate and changes the App ownerRevision.
        state.present(newSheet)
        let nextOwner = try directoryRequestID(.current(directoryAnchor(640)), state: &state)
        let previousOwner = state.apply(value, request: new)
        let oldDismissal = state.dismiss(oldSheet)
        #expect(!oldDismissal && state.ownsPresentation(newSheet))
        #expect(!previousOwner && state.requestID == nextOwner)
    }
    @Test func duplicateRequestsAndLateCancelCannotClearTheNewPage() throws {
        var state = DirectoryPresentation()
        let presentation = UUID(), current = DirectoryRequest.current(directoryAnchor(0))
        state.present(presentation)
        let initial = try directoryRequestID(current, state: &state)
        state.cancel() // Suspending retains the sheet and anchor, but retires its first lookup.
        #expect(state.page == nil && !state.loading && state.ownsPresentation(presentation))
        let resumed = try directoryRequestID(current, state: &state)
        let cancelledInitial = state.fail("cancelled first lookup", request: initial)
        #expect(resumed != initial && state.requestID == resumed && !cancelledInitial)
        state.cancel()
        let first = try directoryRequestID(.page(0), state: &state)
        let duplicate = state.begin(.page(0))
        #expect(duplicate == nil && state.requestID == first)
        state.cancel()
        let next = try directoryRequestID(.page(32), state: &state)
        let late = state.fail("cancelled old task", request: first)
        #expect(!late && state.requestID == next && state.loading)
        let value = ReadingDirectoryPage(start: 32, total: 33, currentIndex: 32, chapters: [try directoryChapter(32)])
        let completed = state.apply(value, request: next)
        let duplicateLoaded = state.begin(.page(32))
        #expect(completed && duplicateLoaded == nil)
        let request = try directoryRequestID(.page(0), state: &state)
        let failed = state.fail("retry", request: request)
        #expect(failed && state.page?.start == 32 && state.message != nil)
    }
    @Test func onlyExplicitCurrentRevealSurvivesAndPagingDismissalOrStaleDisplayRevokesIt() throws {
        var state = DirectoryPresentation()
        let chapter = try directoryChapter(31)
        let page = ReadingDirectoryPage(start: 0, total: 64, currentIndex: 31, chapters: try (0..<32).map { try directoryChapter($0) })
        let opened = try directoryRequestID(.current(directoryAnchor(310)), state: &state)
        let applied = state.apply(page, request: opened, revealCurrent: true)
        let reveal = try #require(state.reveal)
        #expect(applied && reveal.chapterID == chapter.id)
        let paging = try directoryRequestID(.page(32), state: &state)
        #expect(state.reveal == nil) // A queued scroll/focus for the old ID must stop.
        let nextPage = ReadingDirectoryPage(start: 32, total: 64, currentIndex: 31, chapters: try (32..<64).map { try directoryChapter($0) })
        let auto = state.apply(nextPage, request: paging, revealCurrent: false)
        #expect(auto && state.reveal == nil)
        let changed = try directoryRequestID(.current(directoryAnchor(310)), state: &state)
        let stalePosition = state.apply(page, request: changed, revealCurrent: true, locationStillCurrent: false)
        #expect(stalePosition && state.page?.currentIndex == nil && state.reveal == nil)
        state.cancel()
        #expect(state.reveal == nil && !state.loading)
    }
    @Test func actualQueryRejectsOtherBooksVersionsBOMInteriorsAndClosedReaders() async throws {
        let f = try await DerivedBookFixture(bytes: Data([0xEF, 0xBB, 0xBF]) + Data("Chapter 1\ntext".utf8))
        defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        await #expect(throws: LibraryError.invalidAnchor) {
            try await reader.directory(around: ReadingAnchor(bookID: "other", versionID: f.book.versionID, rawByteOffset: 3))
        }
        await #expect(throws: LibraryError.invalidAnchor) {
            try await reader.directory(around: ReadingAnchor(bookID: f.book.id, versionID: "old", rawByteOffset: 3))
        }
        await #expect(throws: TXTError.invalidByteBoundary(RawByteOffset(1))) {
            try await reader.directory(around: ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 1))
        }
        try await reader.close()
        await #expect(throws: DerivedStorageError.closed) {
            try await reader.directory(around: ReadingAnchor(bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: 3))
        }
    }
}
