import Foundation
import GRDB
import Testing
import TXTCore
@testable import ReaderDomain

struct ReadingBookmarkTests {
    private func anchor(_ book: LibraryBook, _ raw: Int = 0) -> ReadingAnchor {
        ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: raw, lineFraction: 0.7)
    }
    private func queue(_ f: DerivedBookFixture) throws -> DatabaseQueue {
        try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
    }
    private func state(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try ["books", "progress", "preferences", "derivedArtifacts"].flatMap { table in
                let columns = try db.columns(in: table).map { "quote(\"\($0.name)\")" }.joined(separator: " || '|' || ")
                return try String.fetchAll(db, sql: "SELECT \(columns) FROM \(table) ORDER BY 1")
            }
        }
    }

    @Test func bookmarkMigrationPreservesV3RowsAndRollsBackFailure() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let old = try DatabaseQueue(path: f.root.appendingPathComponent("v3.sqlite").path)
        try LibrarySchema.migrator().migrate(old, upTo: "v3-derived-pointers")
        try await old.write { db in
            try f.book.insert(db)
            try db.execute(sql: "INSERT INTO progress VALUES (?, ?, 'raw-byte-v1', 0, 0.4, 'old-session', 9)", arguments: [f.book.id, f.book.versionID])
            try db.execute(sql: "INSERT INTO preferences VALUES (1, ?)", arguments: [try JSONEncoder().encode(ReaderPreferences(fontSize: 28, lineSpacing: 11, theme: .dark))])
            try db.execute(sql: "INSERT INTO derivedArtifacts VALUES (?, ?, ?, ?, 4096)", arguments: [f.book.id, f.book.versionID, UUID().uuidString.lowercased(), String(repeating: "a", count: 64)])
            try db.execute(sql: "CREATE INDEX bookmarks_book_created_id ON books(title)")
        }
        let before = try state(old)
        #expect(throws: (any Error).self) { try LibrarySchema.migrator().migrate(old) }
        #expect(try state(old) == before)
        let absent = try await old.read { db in try !db.tableExists("bookmarks") }
        #expect(absent)
        try await old.write { db in try db.execute(sql: "DROP INDEX bookmarks_book_created_id") }
        try LibrarySchema.migrator().migrate(old)
        #expect(try state(old) == before)
        let count = try await old.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks") }
        #expect(count == 0)
        let v4 = try DatabaseQueue(path: f.root.appendingPathComponent("v4.sqlite").path)
        try LibrarySchema.migrator().migrate(v4, upTo: "v4-bookmarks")
        let legacy = ReadingBookmark(id: UUID().uuidString, bookID: f.book.id, versionID: f.book.versionID,
                                     rawByteOffset: 3, createdAt: 123, chapterTitleSnapshot: "旧章节")
        try await v4.write { db in
            try f.book.insert(db)
            try db.execute(sql: "INSERT INTO progress VALUES (?, ?, 'raw-byte-v1', 3, 0.2, 'v4-session', 11)", arguments: [f.book.id, f.book.versionID])
            try db.execute(sql: "INSERT INTO preferences VALUES (1, ?)", arguments: [try JSONEncoder().encode(ReaderPreferences())])
            try db.execute(sql: "INSERT INTO derivedArtifacts VALUES (?, ?, ?, ?, 4096)", arguments: [f.book.id, f.book.versionID, UUID().uuidString.lowercased(), String(repeating: "b", count: 64)])
            try db.execute(sql: "INSERT INTO bookmarks VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [legacy.id, legacy.bookID, legacy.versionID, legacy.unit,
                            legacy.rawByteOffset, legacy.createdAt, legacy.chapterTitleSnapshot])
        }
        let v4State = try state(v4)
        try LibrarySchema.migrator().migrate(v4)
        let migrated = try await v4.read { db in try ReadingBookmark.fetchOne(db, key: legacy.id) }
        #expect(migrated == legacy)
        #expect(migrated?.customName == nil && migrated?.displayTitle == "旧章节")
        #expect(try state(v4) == v4State)
    }

    @Test func bookmarkConcurrentRetriesKeepOriginalIdentityAndTime() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let position = anchor(f.book), id = UUID()
        async let first = reader.addBookmark(at: position, id: id, request: BookmarkRequest())
        async let second = reader.addBookmark(at: position, request: BookmarkRequest())
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(try await reader.addBookmark(at: position, id: id, request: BookmarkRequest()) == a)
        #expect(try await reader.bookmark(at: position, request: BookmarkRequest()) == a)
        #expect(try await reader.bookmarkAnchor(id: a.id, request: BookmarkRequest()).lineFraction == 0)
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).total == 1)
        let named = try await reader.addBookmark(at: anchor(f.book, 1), name: "  添加时命名 👩‍💻  ", request: BookmarkRequest())
        #expect(named.customName == "添加时命名 👩‍💻" && named.displayTitle == "添加时命名 👩‍💻")
        #expect(try await reader.addBookmark(at: anchor(f.book, 1), name: "不得覆盖原名", request: BookmarkRequest()) == named)
        #expect(try await reader.bookmark(at: anchor(f.book, 1), request: BookmarkRequest()) == named)
        try await reader.deleteBookmark(id: named.id, request: BookmarkRequest())
        let blank = try await reader.addBookmark(at: anchor(f.book, 2), name: " \n\t ", request: BookmarkRequest())
        #expect(blank.customName == nil && blank.displayTitle == "阅读位置")
        try await reader.deleteBookmark(id: blank.id, request: BookmarkRequest())
        try await reader.close()
        let long = try await DerivedBookFixture(bytes: Data(("Chapter 1\n" + String(repeating: "abcdef", count: 2000)).utf8))
        defer { long.remove() }
        let nearbyReader = try await long.service.openReader(id: long.book.id, budget: long.budget)
        #expect(nearbyReader.source.metadata.chapterCount == 1)
        let near = try await nearbyReader.addBookmark(at: anchor(long.book, 12), request: BookmarkRequest())
        let next = try await nearbyReader.addBookmark(at: anchor(long.book, 15), request: BookmarkRequest())
        #expect(near.id != next.id && near.chapterTitleSnapshot == next.chapterTitleSnapshot)
        #expect(try await nearbyReader.addBookmark(at: anchor(long.book, 12), request: BookmarkRequest()) == near)
        #expect(try await nearbyReader.bookmarkPage(start: 0, request: BookmarkRequest()).total == 2)
        #expect(try await nearbyReader.bookmarkAnchor(id: near.id, request: BookmarkRequest()).rawByteOffset == 12)
        #expect(try await nearbyReader.bookmarkAnchor(id: next.id, request: BookmarkRequest()).rawByteOffset == 15)
        try await nearbyReader.close()
    }

    @Test func bookmarkUUIDCollisionAndDatabaseConstraintsNeverReplaceRows() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget), id = UUID()
        let first = try await reader.addBookmark(at: anchor(f.book), id: id, request: BookmarkRequest())
        await #expect(throws: LibraryError.invalidAnchor) { try await reader.addBookmark(at: anchor(f.book, 1), id: id, request: BookmarkRequest()) }
        let db = try queue(f)
        await #expect(throws: (any Error).self) {
            try await db.write { db in
                try ReadingBookmark(id: UUID().uuidString, bookID: f.book.id, versionID: f.book.versionID,
                                    rawByteOffset: 0, createdAt: 999).insert(db)
            }
        }
        for raw in [-1, 1] {
            await #expect(throws: (any Error).self) {
                try await db.write { db in
                    try ReadingBookmark(id: UUID().uuidString, bookID: f.book.id, versionID: f.book.versionID,
                        unit: raw < 0 ? "raw-byte-v1" : "utf16", rawByteOffset: raw, createdAt: 0).insert(db)
                }
            }
        }
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [first])
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 80)
        #expect(try ReadingBookmark.validatedCustomName(" \n" + emoji + "\t ") == emoji)
        #expect(try ReadingBookmark.validatedCustomName(String(repeating: "e\u{301}", count: 80))?.count == 80)
        #expect(try ReadingBookmark.validatedCustomName(" \n\t ") == nil)
        #expect(first.displayTitle == "阅读位置")
        let named = try await reader.renameBookmark(id: first.id, name: emoji, request: BookmarkRequest())
        #expect(named.customName == emoji && named.displayTitle == emoji)
        #expect(named.hasSamePosition(as: first) && named.createdAt == first.createdAt)
        #expect(try await reader.bookmarkAnchor(id: named.id, request: BookmarkRequest()).rawByteOffset == first.rawByteOffset)
        await #expect(throws: ReadingBookmark.NameValidationError.tooLong) {
            try await reader.renameBookmark(id: first.id, name: emoji + "a", request: BookmarkRequest())
        }
        for invalid in ["a\nb", "a\rb", "a\tb", "a\u{0}b", "a\u{7F}b", "a\u{85}b", "a\u{2028}b", "a\u{2029}b"] {
            await #expect(throws: ReadingBookmark.NameValidationError.invalidCharacters) {
                try await reader.renameBookmark(id: first.id, name: invalid, request: BookmarkRequest())
            }
        }
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [named])
        let cleared = try await reader.renameBookmark(id: first.id, name: " \n\t ", request: BookmarkRequest())
        #expect(cleared == first && cleared.displayTitle == "阅读位置")
        await #expect(throws: LibraryError.invalidAnchor) {
            try await reader.renameBookmark(id: UUID().uuidString, name: "missing", request: BookmarkRequest())
        }
        for invalid in [String(repeating: "a", count: 81), "a\nb", "a\u{0}b"] {
            await #expect(throws: ReadingBookmark.NameValidationError.self) {
                try await reader.addBookmark(at: anchor(f.book, 1), name: invalid, request: BookmarkRequest())
            }
        }
        let namedOnInsert = try await reader.addBookmark(at: anchor(f.book, 1), name: emoji, request: BookmarkRequest())
        #expect(namedOnInsert.customName == emoji && namedOnInsert.customName?.count == 80)
        try await reader.deleteBookmark(id: namedOnInsert.id, request: BookmarkRequest())
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [first])
        try await reader.close()
    }

    @Test func bookmarkPagesAreBoundedOrderedAndClampAfterLastPageDeletion() async throws {
        let f = try await DerivedBookFixture(bytes: Data(String(repeating: "x", count: 80).utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget), db = try queue(f)
        let values = (0..<65).map { index in
            ReadingBookmark(id: String(format: "00000000-0000-0000-0000-%012d", index), bookID: f.book.id,
                versionID: f.book.versionID, rawByteOffset: index, createdAt: index < 33 ? 1 : 2)
        }
        try await db.write { db in for value in values { try value.insert(db) } }
        let expected = values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        let first = try await reader.bookmarkPage(start: 0, request: BookmarkRequest())
        let middle = try await reader.bookmarkPage(start: 32, request: BookmarkRequest())
        let last = try await reader.bookmarkPage(start: 64, request: BookmarkRequest())
        #expect(first.items.count == 32 && middle.items.count == 32 && last.items.count == 1)
        #expect(first.items + middle.items + last.items == expected)
        #expect(!first.hasPrevious && first.hasNext && last.hasPrevious && !last.hasNext)
        try await reader.deleteBookmark(id: expected[64].id, request: BookmarkRequest())
        let clamped = try await reader.bookmarkPage(start: 64, request: BookmarkRequest())
        #expect(clamped.start == 32 && clamped.total == 64 && clamped.items == middle.items)
        let renamed = try await reader.renameBookmark(id: expected[0].id, name: "排序不变", request: BookmarkRequest())
        let renamedPage = try await reader.bookmarkPage(start: 0, request: BookmarkRequest())
        #expect(renamedPage.items.map(\.id) == first.items.map(\.id))
        #expect(renamed.createdAt == expected[0].createdAt && renamedPage.total == 64)
        for invalid in [-32, 1, 33] {
            await #expect(throws: LibraryError.invalidAnchor) { try await reader.bookmarkPage(start: invalid, request: BookmarkRequest()) }
        }
        try await reader.close()
    }

    @Test func bookmarkQueriesAndDeletionAreIsolatedBetweenBooks() async throws {
        let f = try await DerivedBookFixture(bytes: Data("first book".utf8)); defer { f.remove() }
        let next = try await importForReader("second book", fixture: f, service: f.service, budget: f.budget)
        let first = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let second = try await f.service.openReader(id: next.book.id, budget: f.budget)
        let a = try await first.addBookmark(at: anchor(f.book), request: BookmarkRequest())
        let b = try await second.addBookmark(at: anchor(next.book), request: BookmarkRequest())
        try await second.deleteBookmark(id: a.id, request: BookmarkRequest())
        await #expect(throws: LibraryError.invalidAnchor) { try await second.bookmarkAnchor(id: a.id, request: BookmarkRequest()) }
        await #expect(throws: LibraryError.invalidAnchor) { try await second.addBookmark(at: anchor(f.book), request: BookmarkRequest()) }
        await #expect(throws: LibraryError.invalidAnchor) {
            try await second.renameBookmark(id: a.id, name: "wrong book", request: BookmarkRequest())
        }
        #expect(try await first.bookmarkPage(start: 0, request: BookmarkRequest()).items == [a])
        #expect(try await second.bookmarkPage(start: 0, request: BookmarkRequest()).items == [b])
        try await first.close(); try await second.close()
    }

    @Test func bookmarkStrictBoundariesCoverFiveEncodingsBOMCRLFAndGraphemes() async throws {
        for encoding in [TXTEncoding.utf8, .utf16LE, .utf16BE, .gbk, .gb18030] {
            let text = encoding == .gbk ? "中A\r\n文B" : "中😀e\u{301}\r\n文B"
            let bytes = try DerivedBookFixture.bytes(text, encoding: encoding, bom: true)
            let f = try await DerivedBookFixture(bytes: bytes, encoding: encoding)
            defer { f.remove() }
            let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
            var valid: Set<Int> = [], utf16 = 0
            for character in f.document.text {
                valid.insert(try f.document.offsets.rawByteOffset(for: UTF16Offset(utf16)).value)
                utf16 += String(character).utf16.count
            }
            for raw in 0...bytes.count {
                let position = anchor(f.book, raw)
                if valid.contains(raw) {
                    let value = try await reader.addBookmark(at: position, request: BookmarkRequest())
                    let restored = try await reader.bookmarkAnchor(id: value.id, request: BookmarkRequest())
                    #expect(restored.rawByteOffset == raw && restored.lineFraction == 0)
                    let named = try await reader.renameBookmark(id: value.id, name: "坐标😀", request: BookmarkRequest())
                    #expect(named.hasSamePosition(as: value) && named.createdAt == value.createdAt)
                    #expect(try await reader.bookmarkAnchor(id: value.id, request: BookmarkRequest()) == restored)
                } else {
                    await #expect(throws: (any Error).self) { try await reader.addBookmark(at: position, request: BookmarkRequest()) }
                }
            }
            #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).total == valid.count)
            try await reader.close()
        }
    }

    @Test func bookmarkEmptyEOFAndCorruptRecordsNeverFallbackToStart() async throws {
        let empty = try await DerivedBookFixture(bytes: Data()); defer { empty.remove() }
        let emptyStart = try await empty.store.beginReading(bookID: empty.book.id, versionID: empty.book.versionID)
        await #expect(throws: LibraryError.invalidAnchor) {
            try await empty.store.addBookmark(session: emptyStart.session, anchor: anchor(empty.book), id: UUID(),
                chapterTitle: nil, request: BookmarkRequest())
        }
        #expect(try await empty.store.bookmarkPage(session: emptyStart.session, start: 0, request: BookmarkRequest()).total == 0)
        try await empty.store.finishReading(session: emptyStart.session, anchor: nil, sequence: 1)
        let f = try await DerivedBookFixture(bytes: Data("😀x".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget), db = try queue(f)
        for raw in [1, f.book.byteCount] {
            let row = ReadingBookmark(id: UUID().uuidString, bookID: f.book.id, versionID: f.book.versionID, rawByteOffset: raw, createdAt: 0)
            try await db.write { db in try row.insert(db) }
            // Structural compatibility alone is deliberately not proof of a valid mapped boundary.
            #expect((row.anchor(matching: f.book) != nil) == (raw < f.book.byteCount))
            await #expect(throws: (any Error).self) { try await reader.bookmarkAnchor(id: row.id, request: BookmarkRequest()) }
            try await reader.deleteBookmark(id: row.id, request: BookmarkRequest())
        }
        await #expect(throws: LibraryError.invalidAnchor) { try await reader.bookmarkAnchor(id: UUID().uuidString, request: BookmarkRequest()) }
        #expect(try await reader.bookmarkPage(start: 32, request: BookmarkRequest()).start == 0)
        await #expect(throws: LibraryError.invalidAnchor) {
            try await reader.renameBookmark(id: UUID().uuidString, name: "missing", request: BookmarkRequest())
        }
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).total == 0)
        try await reader.close()
    }

    @Test func bookmarkIncompatibleVersionsRemainVisibleAndExplicitlyDeletable() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget), db = try queue(f)
        let old = ReadingBookmark(id: UUID().uuidString, bookID: f.book.id, versionID: String(repeating: "f", count: 64), rawByteOffset: 0, createdAt: 0)
        try await db.write { db in try old.insert(db) }
        #expect(old.anchor(matching: f.book) == nil)
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [old])
        await #expect(throws: LibraryError.invalidAnchor) { try await reader.bookmarkAnchor(id: old.id, request: BookmarkRequest()) }
        let renamedOld = try await reader.renameBookmark(id: old.id, name: "旧版本", request: BookmarkRequest())
        #expect(renamedOld.hasSamePosition(as: old) && renamedOld.createdAt == old.createdAt)
        #expect(renamedOld.customName == "旧版本" && renamedOld.anchor(matching: f.book) == nil)
        await #expect(throws: LibraryError.invalidAnchor) { try await reader.bookmarkAnchor(id: old.id, request: BookmarkRequest()) }
        try await reader.deleteBookmark(id: old.id, request: BookmarkRequest())
        try await reader.deleteBookmark(id: old.id, request: BookmarkRequest())
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).total == 0)
        try await db.write { db in try db.execute(sql: "UPDATE books SET versionID = ? WHERE id = ?", arguments: [old.versionID, f.book.id]) }
        await #expect(throws: CancellationError.self) { try await reader.addBookmark(at: anchor(f.book), request: BookmarkRequest()) }
        try await reader.close()
    }

    @Test func bookmarkPersistenceSurvivesNewStoreDuplicateImportAndCacheRebuild() async throws {
        let f = try await DerivedBookFixture(); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let value = try await reader.addBookmark(at: anchor(f.book), request: BookmarkRequest())
        try await reader.close()
        let (pack, _) = try await f.artifact()
        try FileManager.default.removeItem(at: pack)
        let freshStore = try LibraryStore(root: f.managed), freshService = LibraryService(store: freshStore)
        let ticket = UUID(); try await freshStore.beginImport(ticket)
        try f.document.originalBytes.write(to: await freshStore.stagingURL(ticket: ticket))
        let duplicate = try await freshStore.commitImport(ticket: ticket, proposed: f.book)
        #expect(duplicate.duplicate && duplicate.book.id == f.book.id)
        let reopened = try await freshService.openReader(id: f.book.id, budget: f.budget)
        #expect(reopened.cacheDisposition == .rebuilt)
        #expect(try await reopened.bookmarkPage(start: 0, request: BookmarkRequest()).items == [value])
        #expect(try await reopened.bookmarkAnchor(id: value.id, request: BookmarkRequest()).rawByteOffset == value.rawByteOffset)
        let named = try await reopened.renameBookmark(id: value.id, name: " \n重启名称 \t", request: BookmarkRequest())
        #expect(named.customName == "重启名称" && named.displayTitle == "重启名称")
        #expect(named.hasSamePosition(as: value) && named.createdAt == value.createdAt)
        try await reopened.close()
        let restartStore = try LibraryStore(root: f.managed)
        let restartReader = try await LibraryService(store: restartStore).openReader(id: f.book.id, budget: f.budget)
        #expect(try await restartReader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [named])
        #expect(try await restartReader.bookmarkAnchor(id: named.id, request: BookmarkRequest()).rawByteOffset == value.rawByteOffset)
        let restored = try await restartReader.renameBookmark(id: named.id, name: "", request: BookmarkRequest())
        #expect(restored == value && restored.displayTitle == value.chapterTitleSnapshot)
        try await restartReader.close()
        // A fresh Store in-process tests persistence, not actual App process-restart behavior.
    }

    @Test func bookmarkMutationsPreserveProgressSettingsAndDerivedPointers() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget), db = try queue(f)
        #expect(try await reader.saveProgress(anchor(f.book, 2), sequence: 7))
        #expect(try await reader.savePreferences(ReaderPreferences(fontSize: 28, lineSpacing: 11, theme: .dark), sequence: 3))
        let before = try state(db)
        let value = try await reader.addBookmark(at: anchor(f.book, 3), request: BookmarkRequest())
        #expect(try state(db) == before)
        let renamed = try await reader.renameBookmark(id: value.id, name: "精确位置", request: BookmarkRequest())
        #expect(renamed.hasSamePosition(as: value))
        #expect(renamed.createdAt == value.createdAt && renamed.chapterTitleSnapshot == value.chapterTitleSnapshot)
        #expect(try await reader.bookmarkAnchor(id: value.id, request: BookmarkRequest()) == value.anchor(matching: f.book))
        #expect(try state(db) == before)
        #expect(try await reader.addBookmark(at: anchor(f.book, 3), request: BookmarkRequest()) == renamed)
        for changed in [
            ReadingBookmark(id: UUID().uuidString, bookID: value.bookID, versionID: value.versionID, rawByteOffset: value.rawByteOffset, createdAt: value.createdAt),
            ReadingBookmark(id: value.id, bookID: "other", versionID: value.versionID, rawByteOffset: value.rawByteOffset, createdAt: value.createdAt),
            ReadingBookmark(id: value.id, bookID: value.bookID, versionID: "other", rawByteOffset: value.rawByteOffset, createdAt: value.createdAt),
            ReadingBookmark(id: value.id, bookID: value.bookID, versionID: value.versionID, unit: "utf16", rawByteOffset: value.rawByteOffset, createdAt: value.createdAt),
            ReadingBookmark(id: value.id, bookID: value.bookID, versionID: value.versionID, rawByteOffset: 4, createdAt: value.createdAt)
        ] { #expect(renamed.hasSamePosition(as: changed) == false) }
        try await reader.deleteBookmark(id: value.id, request: BookmarkRequest())
        try await reader.deleteBookmark(id: value.id, request: BookmarkRequest())
        let directlyNamed = try await reader.addBookmark(at: anchor(f.book, 5), name: "创建时名称", request: BookmarkRequest())
        #expect(directlyNamed.customName == "创建时名称")
        #expect(try state(db) == before)
        try await reader.deleteBookmark(id: directlyNamed.id, request: BookmarkRequest())
        #expect(try state(db) == before)
        #expect(try await reader.saveProgress(anchor(f.book, 4), sequence: 6) == false)
        #expect(try Data(contentsOf: await f.store.fileURL(bookID: f.book.id)) == f.document.originalBytes)
        try await reader.close()
    }

    @Test func bookmarkRevokedRequestAndCancelledTaskCannotWrite() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let saved = try await reader.addBookmark(at: anchor(f.book), request: BookmarkRequest())
        let request = BookmarkRequest(); request.cancel()
        #expect(request.isCancelled)
        await #expect(throws: CancellationError.self) { try await reader.addBookmark(at: anchor(f.book, 1), request: request) }
        await #expect(throws: CancellationError.self) {
            try await reader.addBookmark(at: anchor(f.book, 1), name: "取消新增名称", request: request)
        }
        await #expect(throws: CancellationError.self) { try await reader.deleteBookmark(id: saved.id, request: request) }
        await #expect(throws: CancellationError.self) { try await reader.bookmarkPage(start: 0, request: request) }
        await #expect(throws: CancellationError.self) { try await reader.renameBookmark(id: saved.id, name: "cancelled", request: request) }
        let renameGate = ReaderTestGate()
        let renameTask = Task {
            await renameGate.pause()
            return try await reader.renameBookmark(id: saved.id, name: "cancelled task", request: BookmarkRequest())
        }
        try await renameGate.wait(); renameTask.cancel(); await renameGate.release()
        await #expect(throws: CancellationError.self) { try await renameTask.value }
        let gate = ReaderTestGate(), position = anchor(f.book, 2)
        let task = Task { await gate.pause(); return try await reader.addBookmark(at: position, request: BookmarkRequest()) }
        try await gate.wait(); task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [saved])
        try await reader.close()
    }

    @Test func bookmarkSupersededAndClosedSessionsLoseAdmission() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let old = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let saved = try await old.addBookmark(at: anchor(f.book), request: BookmarkRequest())
        let current = try await f.service.openReader(id: f.book.id, budget: f.budget)
        await #expect(throws: CancellationError.self) { try await old.addBookmark(at: anchor(f.book, 1), request: BookmarkRequest()) }
        await #expect(throws: CancellationError.self) { try await old.deleteBookmark(id: saved.id, request: BookmarkRequest()) }
        await #expect(throws: CancellationError.self) { try await old.bookmarkPage(start: 0, request: BookmarkRequest()) }
        await #expect(throws: CancellationError.self) { try await old.renameBookmark(id: saved.id, name: "superseded", request: BookmarkRequest()) }
        try await old.close()
        await #expect(throws: DerivedStorageError.closed) { try await old.bookmarkAnchor(id: saved.id, request: BookmarkRequest()) }
        #expect(try await current.bookmarkPage(start: 0, request: BookmarkRequest()).items == [saved])
        try await current.close()
        await #expect(throws: DerivedStorageError.closed) { try await current.addBookmark(at: anchor(f.book, 2), request: BookmarkRequest()) }
        await #expect(throws: DerivedStorageError.closed) { try await current.renameBookmark(id: saved.id, name: "closed", request: BookmarkRequest()) }
        await #expect(throws: CancellationError.self) {
            try await f.store.deleteBookmark(session: current.reading.session, id: saved.id, request: BookmarkRequest())
        }
        let reopened = try await f.service.openReader(id: f.book.id, budget: f.budget)
        #expect(try await reopened.bookmarkPage(start: 0, request: BookmarkRequest()).items == [saved])
        try await reopened.close()
    }

    @Test func bookmarkPostCommitCancellationReturnsCommittedTruthAndCapsTitle() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget)
        let request = BookmarkRequest(), title = String(repeating: "e\u{301}😀", count: 90), position = anchor(f.book)
        let task = Task {
            try await f.store.addBookmark(session: reader.reading.session, anchor: position, id: UUID(), chapterTitle: title,
                request: request, afterCommit: { request.cancel(); withUnsafeCurrentTask { $0?.cancel() } })
        }
        let committed = try await task.value
        #expect(request.isCancelled && committed.chapterTitleSnapshot == String(title.prefix(80)))
        #expect(committed.chapterTitleSnapshot?.count == 80)
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [committed])
        #expect(try await reader.addBookmark(at: position, request: BookmarkRequest()) == committed)
        let renameRequest = BookmarkRequest()
        let renameTask = Task {
            try await f.store.renameBookmark(session: reader.reading.session, id: committed.id, name: "committed rename",
                request: renameRequest, afterCommit: { renameRequest.cancel(); withUnsafeCurrentTask { $0?.cancel() } })
        }
        let renamed = try await renameTask.value
        #expect(renameRequest.isCancelled && renamed.customName == "committed rename")
        #expect(renamed.hasSamePosition(as: committed) && renamed.createdAt == committed.createdAt)
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [renamed])
        let namedRequest = BookmarkRequest()
        let namedCommit = try await f.store.addBookmark(session: reader.reading.session, anchor: anchor(f.book, 1),
            id: UUID(), chapterTitle: nil, name: "原子命名", request: namedRequest, afterCommit: { namedRequest.cancel() })
        #expect(namedRequest.isCancelled && namedCommit.customName == "原子命名")
        #expect(try await reader.bookmark(at: anchor(f.book, 1), request: BookmarkRequest()) == namedCommit)
        try await reader.close()
    }

    @Test func bookmarkSQLFailuresRollbackAndReadFailureIsNotAnEmptyPage() async throws {
        let f = try await DerivedBookFixture(bytes: Data("abcdef".utf8)); defer { f.remove() }
        let reader = try await f.service.openReader(id: f.book.id, budget: f.budget), db = try queue(f)
        let saved = try await reader.addBookmark(at: anchor(f.book), request: BookmarkRequest())
        let before = try state(db)
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER bookmark_insert_failure AFTER INSERT ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
            try db.execute(sql: "CREATE TRIGGER bookmark_delete_failure AFTER DELETE ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
            try db.execute(sql: "CREATE TRIGGER bookmark_rename_failure AFTER UPDATE OF customName ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
        }
        await #expect(throws: (any Error).self) { try await reader.addBookmark(at: anchor(f.book, 1), request: BookmarkRequest()) }
        await #expect(throws: (any Error).self) {
            try await reader.addBookmark(at: anchor(f.book, 2), name: "名称与书签一起回滚", request: BookmarkRequest())
        }
        await #expect(throws: (any Error).self) { try await reader.deleteBookmark(id: saved.id, request: BookmarkRequest()) }
        await #expect(throws: (any Error).self) { try await reader.renameBookmark(id: saved.id, name: "rollback", request: BookmarkRequest()) }
        #expect(try await reader.bookmarkPage(start: 0, request: BookmarkRequest()).items == [saved])
        #expect(try state(db) == before)
        try await db.write { db in try db.execute(sql: "DROP TRIGGER bookmark_insert_failure; DROP TRIGGER bookmark_delete_failure") }
        // The UPDATE-name failure is still installed: named creation must not call rename.
        let atomic = try await reader.addBookmark(at: anchor(f.book, 2), name: "一次插入", request: BookmarkRequest())
        #expect(atomic.customName == "一次插入")
        try await reader.deleteBookmark(id: atomic.id, request: BookmarkRequest())
        try await db.write { db in try db.execute(sql: "DROP TRIGGER bookmark_rename_failure") }
        let renamed = try await reader.renameBookmark(id: saved.id, name: "retry rename", request: BookmarkRequest())
        #expect(renamed.customName == "retry rename" && renamed.hasSamePosition(as: saved))
        #expect(renamed.createdAt == saved.createdAt)
        #expect(try state(db) == before)
        let retry = try await reader.addBookmark(at: anchor(f.book, 1), request: BookmarkRequest())
        #expect(retry.rawByteOffset == 1 && retry.chapterTitleSnapshot == nil)
        try await reader.deleteBookmark(id: retry.id, request: BookmarkRequest())
        try await db.write { db in try db.execute(sql: "DROP TABLE bookmarks") }
        await #expect(throws: (any Error).self) { try await reader.bookmarkPage(start: 0, request: BookmarkRequest()) }
        #expect(try state(db) == before)
        try await reader.close()
        // Fail only the optional bounded directory page, not the already-proven position.
        let labels = try await DerivedBookFixture(); defer { labels.remove() }
        try await labels.service.buildDerivedBook(id: labels.book.id, budget: labels.budget)
        let limited = try DerivedBookFixture.limits(chapters: 1)
        let limitedReader = try await labels.service.openReader(id: labels.book.id, budget: limited)
        #expect(limitedReader.source.metadata.chapterCount > 1)
        await #expect(throws: DerivedStorageError.budgetExceeded) { try await limitedReader.directory(around: anchor(labels.book)) }
        let withoutLabel = try await limitedReader.addBookmark(at: anchor(labels.book), request: BookmarkRequest())
        #expect(withoutLabel.chapterTitleSnapshot == nil && withoutLabel.rawByteOffset == 0)
        #expect(try await limitedReader.bookmarkAnchor(id: withoutLabel.id, request: BookmarkRequest()).rawByteOffset == 0)
        try await limitedReader.close()
    }
}
