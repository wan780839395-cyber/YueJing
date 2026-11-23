import Foundation
import Testing
@testable import ReaderDomain

struct EPUBUserFontStoreTests {
    // Original structural SFNT fixture, not a system font or a rendering sample.
    private func sfnt(_ name: String = "Paper Finch", otf: Bool = false) -> Data {
        func be16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(truncatingIfNeeded: n)] }
        func be32(_ n: Int) -> [UInt8] { be16(n >> 16) + be16(n & 0xffff) }
        let text = name.utf16.flatMap { be16(Int($0)) }
        let names = [0, 1, 18, 3, 1, 0x409, 4, text.count, 0].flatMap { be16($0) } + text
        var head = Data(repeating: 0, count: 54)
        head.replaceSubrange(12..<16, with: be32(0x5f0f3cf5))
        let tables = [("head", head), ("name", Data(names)), (otf ? "CFF " : "glyf", Data([0]))]
        var result = Data(be32(otf ? 0x4f54544f : 0x10000) + be16(3) + [0, 32, 0, 1, 0, 16])
        var payload = Data()
        for (tag, table) in tables {
            result.append(contentsOf: tag.utf8)
            result.append(contentsOf: be32(0) + be32(60 + payload.count) + be32(table.count))
            payload.append(table)
            while !payload.count.isMultiple(of: 4) { payload.append(0) }
        }
        result.append(payload)
        return result
    }

    @Test func reopenFindsOriginalBytesAndDeduplicatesRenamedSources() async throws {
        let tmp = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("library")
        let store = EPUBUserFontStore(root: root)
        let bytes = sfnt(), source = tmp.appendingPathComponent("first.TTF")
        try bytes.write(to: source)
        let font = try await store.importFont(from: source)
        #expect(font.id == EPUBResourceStore.digest(bytes))
        #expect(font.displayName == "Paper Finch")
        #expect(font.mediaType == "font/ttf")
        let renamed = tmp.appendingPathComponent("another.ttf")
        try FileManager.default.moveItem(at: source, to: renamed)
        let reopened = EPUBUserFontStore(root: root)
        let duplicate = try await reopened.importFont(from: renamed)
        #expect(duplicate == font)
        try FileManager.default.removeItem(at: renamed)
        let list = try await reopened.list(), copy = try await reopened.data(for: font.id)
        #expect(list == [font])
        #expect(copy == bytes)

        let otf = tmp.appendingPathComponent("private-name.otf")
        try sfnt("../untrusted", otf: true).write(to: otf)
        let other = try await reopened.importFont(from: otf)
        #expect(other.mediaType == "font/otf")
        #expect(other.displayName == "Font \(other.id.prefix(12))")
    }

    @Test func invalidSourcesDoNotEnterLibrary() async throws {
        let tmp = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = EPUBUserFontStore(root: tmp.appendingPathComponent("library"))
        for (name, bytes) in [("wrong.woff", sfnt()), ("wrong.otf", sfnt()),
                              ("broken.ttf", Data([0, 1, 0, 0])), ("container.ttf", WOFF2TestFont.data)] {
            let file = tmp.appendingPathComponent(name)
            try bytes.write(to: file)
            await #expect(throws: EPUBError.self) { _ = try await store.importFont(from: file) }
        }
        let link = tmp.appendingPathComponent("link.ttf"), valid = tmp.appendingPathComponent("valid.ttf")
        try sfnt().write(to: valid)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        let dir = tmp.appendingPathComponent("folder.ttf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        for file in [link, dir, URL(string: "https://example.invalid/font.ttf")!] {
            await #expect(throws: EPUBError.unsafePath) { _ = try await store.importFont(from: file) }
        }
        let list = try await store.list()
        #expect(list.isEmpty)
    }

    @Test func lookupRejectsTraversalMissingTamperedAndLinkedBlobs() async throws {
        let tmp = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("library"), source = tmp.appendingPathComponent("keep.ttf")
        try sfnt().write(to: source)
        let store = EPUBUserFontStore(root: root)
        let font = try await store.importFont(from: source)
        let blob = root.appendingPathComponent(font.id)
        await #expect(throws: EPUBError.unsafePath) { _ = try await store.data(for: "../keep.ttf") }
        // Even a different, structurally valid font must not be served for this ID.
        try sfnt("Different").write(to: blob, options: .atomic)
        let reopened = EPUBUserFontStore(root: root)
        await #expect(throws: EPUBError.corruptResource) { _ = try await reopened.data(for: font.id) }
        await #expect(throws: EPUBError.corruptResource) { _ = try await reopened.list() }
        await #expect(throws: EPUBError.corruptResource) { _ = try await reopened.importFont(from: source) }
        try FileManager.default.removeItem(at: blob)
        await #expect(throws: (any Error).self) { _ = try await reopened.data(for: font.id) }
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: source)
        await #expect(throws: (any Error).self) { _ = try await reopened.data(for: font.id) }
        let untouched = try Data(contentsOf: source)
        #expect(untouched == sfnt())
    }

    @Test func enforcesSingleAndLibraryByteLimitsWithoutChargingDuplicates() async throws {
        let tmp = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("library"), source = tmp.appendingPathComponent("budget.ttf")
        let store = EPUBUserFontStore(root: root)
        let limit = 8 * 1024 * 1024
        var bytes = sfnt()
        bytes.append(Data(repeating: 0, count: limit + 1 - bytes.count))
        try bytes.write(to: source)
        await #expect(throws: EPUBError.limitExceeded) { _ = try await store.importFont(from: source) }
        bytes.removeLast()
        var accepted: [EPUBUserFont] = []
        for i in 0..<4 {
            bytes[limit - 1] = UInt8(i)
            try bytes.write(to: source)
            let font = try await store.importFont(from: source)
            accepted.append(font)
        }
        let reopened = EPUBUserFontStore(root: root)
        let duplicate = try await reopened.importFont(from: source)
        #expect(duplicate == accepted[3])
        try sfnt("One too many").write(to: source)
        await #expect(throws: EPUBError.limitExceeded) { _ = try await reopened.importFont(from: source) }
        let actual = try await reopened.list()
        #expect(actual == accepted.sorted { $0.id < $1.id })
    }
}
