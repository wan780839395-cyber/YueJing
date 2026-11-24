import Foundation
import GRDB
import Testing
@testable import ReaderDomain

struct LibraryDeletionTests {
    private func rejectWhileReading(_ book: LibraryBook, session: ReadingSession, in f: EPUBLibraryFixture) async throws {
        // The import receipt predates the session; admission must use current store state.
        await #expect(throws: (any Error).self) { try await f.service.deleteBook(book) }
        #expect(try await f.store.book(id: book.id)?.activeSession == session.id)
    }

    private func deleteAndReimport(_ target: LibraryBook, source: URL, keeping other: LibraryBook,
                                   source otherSource: URL, in f: EPUBLibraryFixture) async throws -> LibraryService {
        try #require(target.id != other.id && target.title == other.title)
        let txt = target.format == .txt
        func managed(_ book: LibraryBook) async throws -> URL {
            if txt { return try await f.store.fileURL(bookID: book.id) }
            return try await f.store.epubFileURL(bookID: book.id)
        }
        let copy = try await managed(target), otherCopy = try await managed(other)
        let bytes = try Data(contentsOf: source), otherBytes = try Data(contentsOf: otherSource)
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(try Data(contentsOf: otherCopy) == otherBytes)

        let db = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
        func checkPersistedOwners(_ ids: [String]) throws {
            for table in (txt ? ["progress", "bookmarks"] : ["epubProgress", "epubBookmarks"]) {
                let owners = try db.read { try String.fetchAll($0, sql: "SELECT bookID FROM \(table) ORDER BY bookID") }
                #expect(owners == ids.sorted(), "Unexpected persisted owners in \(table)")
            }
        }
        try checkPersistedOwners([target.id, other.id])
        try await f.service.deleteBook(target)
        // Check before constructing another store: startup reconciliation could remove an orphan file.
        try checkPersistedOwners([other.id])
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try Data(contentsOf: otherCopy) == otherBytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: otherSource) == otherBytes)

        let store = try LibraryStore(root: f.managed), fresh = LibraryService(store: store)
        #expect(try await store.books().map(\.id) == [other.id])
        let result = try await fresh.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = result else { throw LibraryError.invalidEncoding }
        #expect(!receipt.duplicate && receipt.book.id == target.id)
        return fresh
    }

    @Test func deleteTXTBookPreservesSameTitleSiblingAndReimportsWithoutReadingState() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = f.root.appendingPathComponent("Twin.txt")
        let folder = f.root.appendingPathComponent("Sibling")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let siblingSource = folder.appendingPathComponent(source.lastPathComponent)
        try Data("First synthetic text.\n".utf8).write(to: source)
        try Data("Second synthetic text.\n".utf8).write(to: siblingSource)
        let book = try await f.install(source).book, sibling = try await f.install(siblingSource).book
        let budget = try ReaderStoragePolicy.budget()
        func seed(_ item: LibraryBook, offset: Int) async throws -> (ReadingAnchor, ReadingBookmark) {
            let reader = try await f.service.openReader(id: item.id, budget: budget)
            let anchor = ReadingAnchor(bookID: item.id, versionID: item.versionID, rawByteOffset: offset)
            let mark = try await reader.addBookmark(at: anchor, request: BookmarkRequest())
            if item.id == book.id { try await rejectWhileReading(item, session: reader.reading.session, in: f) }
            try await reader.close(anchor: anchor)
            return (anchor, mark)
        }
        _ = try await seed(book, offset: 2)
        let (anchor, mark) = try await seed(sibling, offset: 5)
        let fresh = try await deleteAndReimport(book, source: source, keeping: sibling, source: siblingSource, in: f)
        let kept = try await fresh.openReader(id: sibling.id, budget: budget)
        #expect(kept.reading.anchor == anchor)
        #expect(try await kept.bookmarkPage(start: 0, request: BookmarkRequest()).items == [mark])
        try await kept.close()
        let clean = try await fresh.openReader(id: book.id, budget: budget)
        #expect(clean.reading.anchor == nil)
        #expect(try await clean.bookmarkPage(start: 0, request: BookmarkRequest()).total == 0)
        try await clean.close()
    }

    @Test func deleteEPUBBookPreservesSameTitleSiblingAndReimportsWithoutReadingState() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let source = try f.archive(), siblingSource = try f.archive(cover: EPUBLibraryFixture.image(width: 2, height: 2))
        let book = try await f.install(source).book, sibling = try await f.install(siblingSource).book
        func seed(_ item: LibraryBook, offset: Int) async throws -> (EPUBReadingPosition, [EPUBBookmark]) {
            let reader = try await f.service.openEPUB(id: item.id)
            let position = try EPUBLibraryFixture.position(reader, offset: offset)
            let token = try await reader.beginNavigation(path: position.path)
            try #require(try await reader.markReady(token))
            try #require(try await reader.addBookmark(position, title: "Synthetic mark", token: token))
            let marks = try await reader.bookmarks()
            if item.id == book.id { try await rejectWhileReading(item, session: reader.reading.session, in: f) }
            try await reader.close(position: position, sequence: 1, token: token, preferences: reader.preferences)
            return (position, marks)
        }
        _ = try await seed(book, offset: 1)
        let (position, marks) = try await seed(sibling, offset: 5)
        let fresh = try await deleteAndReimport(book, source: source, keeping: sibling, source: siblingSource, in: f)
        let kept = try await fresh.openEPUB(id: sibling.id)
        #expect(kept.reading.position == position)
        #expect(try await kept.bookmarks() == marks)
        try await kept.abandon()
        let clean = try await fresh.openEPUB(id: book.id)
        #expect(clean.reading.position == nil)
        #expect(try await clean.bookmarks().isEmpty)
        try await clean.abandon()
    }
}
