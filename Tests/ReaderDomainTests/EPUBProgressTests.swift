import Foundation
import Testing
@testable import ReaderDomain

struct EPUBProgressTests {
    @Test func epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive())
        let reader = try await f.service.openEPUB(id: receipt.book.id)
        let valid = try EPUBLibraryFixture.position(reader, offset: 1), package = reader.publication.package
        try valid.validate(in: package)
        for offset in [-1, 2, 4, 999999] {
            let bad = EPUBReadingPosition(bookID: valid.bookID, versionID: valid.versionID,
                                           path: valid.path, node: valid.node, utf16Offset: offset)
            #expect(throws: EPUBError.invalidPosition) { try bad.validate(in: package) }
        }
        for bad in [
            EPUBReadingPosition(bookID: "foreign", versionID: valid.versionID, path: valid.path, node: valid.node, utf16Offset: 0),
            EPUBReadingPosition(bookID: valid.bookID, versionID: "old-parser", path: valid.path, node: valid.node, utf16Offset: 0),
            EPUBReadingPosition(bookID: valid.bookID, versionID: valid.versionID, path: "OPS/nav.xhtml", node: 0, utf16Offset: 0),
            EPUBReadingPosition(bookID: valid.bookID, versionID: valid.versionID, path: valid.path, node: -1, utf16Offset: 0),
            EPUBReadingPosition(bookID: valid.bookID, versionID: valid.versionID, path: valid.path, node: valid.node, utf16Offset: 0, unit: "raw-byte-v1")
        ] { #expect(throws: EPUBError.invalidPosition) { try bad.validate(in: package) } }
        let encoded = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(EPUBReadingPosition.self, from: encoded) == valid)
        try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
    }

    @Test func epubProgressRequiresReadinessAndIncreasingSequence() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive()), reader = try await f.service.openEPUB(id: receipt.book.id)
        let position = try EPUBLibraryFixture.position(reader, offset: 1)
        let token = try await reader.beginNavigation(path: position.path)
        #expect(try await reader.save(position, sequence: 1, token: token) == false)
        #expect(try await reader.markReady(token))
        #expect(try await reader.save(position, sequence: 2, token: token))
        let old = try EPUBLibraryFixture.position(reader)
        #expect(try await reader.save(old, sequence: 1, token: token) == false)
        #expect(try await reader.save(old, sequence: 2, token: token) == false)
        await #expect(throws: EPUBError.invalidPosition) { try await reader.save(old, sequence: 0, token: token) }
        async let first: Void = reader.close(position: position, sequence: 3, token: token, preferences: reader.preferences)
        async let second: Void = reader.close(position: position, sequence: 3, token: token, preferences: reader.preferences)
        _ = try await (first, second)
        let next = try await f.service.openEPUB(id: receipt.book.id)
        #expect(next.reading.position == position)
        try await next.close(position: nil, sequence: 1, token: nil, preferences: next.preferences)
    }

    @Test func epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive()), reader = try await f.service.openEPUB(id: receipt.book.id)
        let a = try EPUBLibraryFixture.position(reader), b = try EPUBLibraryFixture.position(reader, path: "OPS/two.xhtml", offset: 1)
        let old = try await reader.beginNavigation(path: a.path)
        #expect(try await reader.markReady(old))
        let current = try await reader.beginNavigation(path: b.path)
        #expect(try await reader.markReady(old) == false)
        #expect(try await reader.save(a, sequence: 100, token: old) == false)
        #expect(try await reader.markReady(current))
        #expect(try await reader.save(b, sequence: 1, token: current))
        let replacement = try await f.service.openEPUB(id: receipt.book.id)
        #expect(replacement.reading.position == b)
        #expect(try await reader.save(b, sequence: 101, token: current) == false)
        try await reader.close(position: b, sequence: 102, token: current, preferences: reader.preferences)
        #expect(try await reader.save(b, sequence: 103, token: current) == false)
        #expect(try await f.store.book(id: receipt.book.id)?.activeSession == replacement.reading.session.id)
        try await replacement.close(position: nil, sequence: 1, token: nil, preferences: replacement.preferences)
    }

    @Test func epubTypographyEpochRestoresSameTextPositionAndSettings() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive()), reader = try await f.service.openEPUB(id: receipt.book.id)
        let anchor = try EPUBLibraryFixture.position(reader, offset: 5)
        let original = try await reader.beginNavigation(path: anchor.path)
        #expect(try await reader.markReady(original))
        #expect(try await reader.save(anchor, sequence: 1, token: original))
        let typography = ReaderPreferences(fontSize: 30, lineSpacing: 12, theme: .dark)
        let reflow = try await reader.beginNavigation(path: anchor.path)
        #expect(original != reflow)
        #expect(try await reader.save(anchor, sequence: 2, token: original) == false)
        #expect(try await reader.save(anchor, sequence: 2, token: reflow) == false)
        #expect(try await reader.markReady(reflow))
        #expect(try await reader.savePreferences(typography, sequence: 1))
        #expect(try await reader.save(anchor, sequence: 2, token: reflow))
        try await reader.close(position: anchor, sequence: 3, token: reflow, preferences: typography)
        let reopened = try await LibraryService(store: LibraryStore(root: f.managed)).openEPUB(id: receipt.book.id)
        #expect(reopened.preferences == typography && reopened.reading.position == anchor)
        try await reopened.close(position: nil, sequence: 1, token: nil, preferences: reopened.preferences)
        // Native WebKit layout restoration is separately verified by the Host/UI cases.
    }

    @Test func epubViewportOffsetPersistsAndLegacyAnchorsRemainReadable() async throws {
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let receipt = try await f.install(f.archive())
        let reader = try await f.service.openEPUB(id: receipt.book.id)
        let anchor = try EPUBLibraryFixture.position(reader, offset: 1)
        // Synthesized Codable must continue to accept old JSON with no optional geometry.
        let legacy = try JSONEncoder().encode(anchor)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(legacyObject["viewportOffset"] == nil)
        #expect(try JSONDecoder().decode(EPUBReadingPosition.self, from: legacy).viewportOffset == nil)
        let position = EPUBReadingPosition(bookID: anchor.bookID, versionID: anchor.versionID,
            path: anchor.path, node: anchor.node, utf16Offset: anchor.utf16Offset, viewportOffset: -7.25)
        try position.validate(in: reader.publication.package)
        let token = try await reader.beginNavigation(path: position.path)
        #expect(try await reader.save(position, sequence: 1, token: token) == false)
        #expect(try await reader.markReady(token))
        #expect(try await reader.save(position, sequence: 2, token: token))
        try await reader.close(position: position, sequence: 3, token: token, preferences: reader.preferences)
        let reopened = try await LibraryService(store: LibraryStore(root: f.managed)).openEPUB(id: receipt.book.id)
        #expect(reopened.reading.position == position)
        for offset in [Double.nan, Double.infinity, -Double.infinity, 16_385, -16_385] {
            let bad = EPUBReadingPosition(bookID: anchor.bookID, versionID: anchor.versionID,
                path: anchor.path, node: anchor.node, utf16Offset: anchor.utf16Offset, viewportOffset: offset)
            #expect(throws: EPUBError.invalidPosition) { try bad.validate(in: reopened.publication.package) }
        }
        try await reopened.close(position: nil, sequence: 1, token: nil, preferences: reopened.preferences)
    }
}
