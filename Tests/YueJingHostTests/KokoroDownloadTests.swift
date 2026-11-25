import Foundation
import Testing
@testable import YueJing

struct KokoroDownloadTests {
    @Test func packDownloadAcceptsOnlyPinnedSourceHostsAndCompleteResponses() throws {
        #expect(KokoroPackDownload.allowed(KokoroPackDownload.official))
        #expect(KokoroPackDownload.allowed(URL(string: "https://release-assets.githubusercontent.com/test")))
        for raw in ["http://github.com/test", "https://github.com.bad.example/test", "https://user@github.com/test", "https://github.com:444/test"] {
            #expect(!KokoroPackDownload.allowed(URL(string: raw)))
        }
        func response(_ status: Int, _ length: String) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: KokoroPackDownload.official, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": length]))
        }
        #expect(KokoroPackDownload.accepts(try response(200, "12"), expected: 12))
        #expect(!KokoroPackDownload.accepts(try response(200, "13"), expected: 12))
        #expect(!KokoroPackDownload.accepts(try response(206, "12"), expected: 12))
        #expect(!KokoroPackDownload.accepts(try response(403, "12"), expected: 12))
    }

    @MainActor @Test func cancelledDownloadAndBadArchiveLeaveSystemUsableAndRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = KokoroPackStore(root: root, defaults: defaults)
        let job = Task { await store.downloadAndInstall { _, progress in
            progress(0.25); try await Task.sleep(for: .seconds(10))
        } }
        let deadline = ContinuousClock.now + .seconds(3)
        while store.downloadProgress != 0.25 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(store.downloadProgress == 0.25); store.cancelDownload(); await job.value
        #expect(!store.isInstalling && store.installedDirectory == nil && store.downloadProgress == nil)
        #expect(store.statusText.contains("取消"))
        await store.downloadAndInstall { destination, _ in try Data("bad".utf8).write(to: destination) }
        #expect(store.installedDirectory == nil && !store.canCancelDownload && store.statusText.contains("失败"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".download").path))
    }
}
