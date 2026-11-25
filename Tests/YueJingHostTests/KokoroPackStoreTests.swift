import Foundation
import Testing
@testable import YueJing

struct KokoroPackStoreTests {
    private static let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private struct Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var root: URL { base.appendingPathComponent("private", isDirectory: true) }
        var source: URL { base.appendingPathComponent(KokoroPackIndex.rootName, isDirectory: true) }
        let index: KokoroPackIndex

        init() throws {
            let row = "\(KokoroPackStoreTests.abc) 3 "
            index = try KokoroPackIndex(text: row + "model.int8.onnx\n" + row + "dict/a\n")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("dict"), withIntermediateDirectories: true)
            for m in index.members { try Data("abc".utf8).write(to: source.appendingPathComponent(m.path)) }
        }
        func clean() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func officialIndexIsBundledAndComplete() throws {
        let files = try KokoroPackIndex.official().members
        #expect(files.count == 376)
        #expect(files.reduce(0) { $0 + $1.bytes } == 215_226_627)
        #expect(files.contains { $0.path == "espeak-ng-data/voices/!v/Mr serious" })
        #expect(!files.contains { $0.path.hasSuffix(".py") })
        let model = try #require(files.first { $0.path == "model.int8.onnx" })
        #expect(model.digest == "05d793700b0b507f760c183c0e39bdd6a97b43d32fdc7bf7b54a5179f1b11222")
    }

    @MainActor @Test func managedLifecyclePreservesPreferenceAndCopiesOnlyPinnedFiles() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let name = UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let store = KokoroPackStore(root: f.root, defaults: prefs, index: f.index)
        try Data("untrusted".utf8).write(to: f.source.appendingPathComponent("manifest.json"))
        await store.install(from: f.source)
        let live = try #require(store.installedDirectory)
        #expect(live.lastPathComponent == KokoroPackIndex.rootName)
        #expect(!FileManager.default.fileExists(atPath: live.appendingPathComponent("manifest.json").path))
        let flags = try f.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(flags.isExcludedFromBackup == true)
        #expect(store.useKokoro && !store.isInstalling)
        #expect(store.revision == KokoroPackIndex.archiveSHA256)
        store.useKokoro = false
        try FileManager.default.removeItem(at: f.source)
        let reopened = KokoroPackStore(root: f.root, defaults: prefs, index: f.index)
        await reopened.install(from: f.source) // waits for cold validation, then fails
        #expect(reopened.installedDirectory == live)
        #expect(!reopened.useKokoro)
        await reopened.remove()
        #expect(reopened.installedDirectory == nil && reopened.revision == nil)
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    @Test func failedReplacementAndCancellationKeepVerifiedInstall() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let d = KokoroPackDisk(root: f.root, index: f.index)
        let live = try await d.install(from: f.source)
        _ = try await d.install(from: f.source) // valid atomic exchange of nonempty directories
        let member = f.source.appendingPathComponent("dict/a")
        for bytes in [Data("bad".utf8), Data("toolong".utf8), nil] as [Data?] {
            if let bytes { try bytes.write(to: member) } else { try FileManager.default.removeItem(at: member) }
            await #expect(throws: KokoroPackError.self) { _ = try await d.install(from: f.source) }
            let restored = try await d.restore()
            #expect(restored == live)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".staging").path))
        }
        try Data("abc".utf8).write(to: member)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await d.install(from: f.source)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        let restored = try await d.restore()
        #expect(restored == live)
        try Data("bad".utf8).write(to: live.appendingPathComponent("dict/a"))
        await #expect(throws: KokoroPackError.self) { _ = try await d.restore() }
    }

    @Test func rejectsLinkedRootDirectoryAndLeafEvenWhenTargetHasCorrectBytes() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let fm = FileManager.default
        let d = KokoroPackDisk(root: f.root, index: f.index)
        let alias = f.base.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: f.source)
        await #expect(throws: KokoroPackError.self) { _ = try await d.install(from: alias) }
        let dir = f.source.appendingPathComponent("dict", isDirectory: true)
        let outside = f.base.appendingPathComponent("outside", isDirectory: true)
        try fm.moveItem(at: dir, to: outside)
        try fm.createSymbolicLink(at: dir, withDestinationURL: outside)
        await #expect(throws: KokoroPackError.self) { _ = try await d.install(from: f.source) }
        try fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("a"), withDestinationURL: outside.appendingPathComponent("a"))
        await #expect(throws: KokoroPackError.self) { _ = try await d.install(from: f.source) }
        let restored = try await d.restore()
        #expect(restored == nil)
    }

    @Test func indexRejectsAbsoluteTraversalAndDuplicateNames() {
        let row = "\(Self.abc) 3 "
        for path in ["/a", "../a", "x/../a", "x//a", "a\\b", "a\n" + row + "A"] {
            #expect(throws: KokoroPackError.self) { _ = try KokoroPackIndex(text: row + path) }
        }
    }
}
