import Foundation
import Testing
@testable import ReaderDomain

struct ImportAdmissionTests {
    @Test func nonTXTAndNonFileSelectionsAreRejectedBeforeSourceAccessAndNeverEnterShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-admission-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("Managed")
        let store = try LibraryStore(root: managed), service = LibraryService(store: store)
        let remote = try #require(URL(string: "https://example.invalid/synthetic.txt"))
        // The missing .bin must be rejected by admission, not by a later file-existence check.
        for source in [root.appendingPathComponent("missing.bin"), remote] {
            let pair = AsyncStream<ImportStage>.makeStream(bufferingPolicy: .bufferingOldest(32))
            let consumer = Task {
                var events: [ImportStage] = []
                for await event in pair.stream { events.append(event) }
                return events
            }
            var rejectedAsNotTXT = false
            do {
                _ = try await service.prepareImport(url: source, ticket: UUID(),
                    observe: { _ = pair.continuation.yield($0) })
            } catch LibraryError.notTXT { rejectedAsNotTXT = true }
            catch { Issue.record("Expected admission rejection before source access") }
            pair.continuation.finish()
            let events = await consumer.value
            #expect(rejectedAsNotTXT)
            #expect(events.isEmpty)
            #expect(try await store.books().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: managed.appendingPathComponent("Imports").path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: managed.appendingPathComponent("Books").path).isEmpty)
        }
    }
}
