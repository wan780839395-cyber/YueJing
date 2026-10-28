#if DEBUG
import Foundation
import ReaderDomain

/// Only an explicit UI-test UUID selects a fresh temporary library. Never opens/removes the user's library.
enum ReadingUITestFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"] != nil }

    static func makeService() async throws -> LibraryService {
        guard let raw = ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"],
              let session = UUID(uuidString: raw) else { throw FixtureError.invalidSession }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-UI-Fixtures", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
        let inputs = root.appendingPathComponent("SyntheticInputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed", isDirectory: true)))
        let longText = (1...40).map { chapter in
            "第\(chapter)章 UI_CHAPTER_\(chapter)\n" + (1...24).map { line in
                "UI_A_C\(chapter)_L\(line) 合成界面测试文本，用于阅读、滚动与位置恢复。\n"
            }.joined()
        }.joined(separator: "\n") + "UI-END-A\n"
        let shortText = "第一章 UI_SHORT_B\n合成短文，用于验证正文末行。\nUI-END-B\n"
        for (name, text) in [("UITest-Long-A", longText), ("UITest-Short-B", shortText)] {
            let source = inputs.appendingPathComponent(name).appendingPathExtension("txt")
            try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: source, options: .atomic)
            let result = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
            guard case .completed = result else { throw FixtureError.unexpectedEncodingChoice }
        }
        return service
    }

    private enum FixtureError: Error { case invalidSession, unexpectedEncodingChoice }
}
#endif
