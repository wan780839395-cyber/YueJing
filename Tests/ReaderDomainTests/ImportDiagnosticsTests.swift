import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

struct ImportDiagnosticsTests {
    @Test func pickerClosureBeforeSuccessDoesNotInventCancellation() {
        let id = UUID()
        var state = ImportDiagnosticState()
        state.begin(id)
        state.pickerClosed(for: id)
        #expect(state.callback == .none)
        #expect(state.callbackSummary == "选择器已关闭，未收到选中文件回调")
        #expect(!state.history.contains(.cancellationCallback))
        let acceptedAfterClosure = state.selected(for: id, hasFile: true)
        #expect(acceptedAfterClosure)
        state.record(.accepted, for: id)
        #expect(state.callback == .selected)
        #expect(state.callbackSummary == "已收到选中文件回调")
        #expect(state.stage == .accepted)
        #expect(state.failure == nil)
        let duplicateSelection = state.selected(for: id, hasFile: true)
        #expect(!duplicateSelection)
    }

    @Test func pickerClosureAfterSuccessPreservesLatestReadingStage() {
        let id = UUID()
        var state = ImportDiagnosticState()
        state.begin(id)
        let acceptedBeforeClosure = state.selected(for: id, hasFile: true)
        #expect(acceptedBeforeClosure)
        state.record(.accepted, for: id)
        state.record(.coordinationStarted, for: id)
        state.pickerClosed(for: id)
        #expect(state.callback == .selected)
        #expect(!state.pickerPresented)
        #expect(state.stage == .coordinationStarted)
        #expect(state.history.last == .pickerClosed)
        #expect(!state.history.contains(.pickerClosedWithoutSelection))
        #expect(!state.history.contains(.cancellationCallback))
    }

    @Test func priorAttemptCallbacksAndStagesCannotOverwriteNewAttempt() {
        let old = UUID(), current = UUID()
        var state = ImportDiagnosticState()
        state.begin(old)
        let acceptedOldSelection = state.selected(for: old, hasFile: true)
        #expect(acceptedOldSelection)
        state.begin(current)
        let expected = state
        state.pickerClosed(for: old)
        state.record(.committed, for: old)
        state.fail(CancellationError(), for: old)
        let staleSelection = state.selected(for: old, hasFile: true)
        #expect(!staleSelection)
        let staleFailure = state.pickerFailed(CancellationError(), for: old)
        #expect(!staleFailure)
        #expect(state == expected)
        let acceptedEmptySelection = state.selected(for: current, hasFile: false)
        #expect(acceptedEmptySelection)
        #expect(state.callback == .empty)
        #expect(state.stage == .emptyCallback)
    }

    @Test func safeFailuresDropPrivateDetailsAndDistinguishRealCancellation() {
        let marker = "SYNTHETIC_PRIVATE_MARKER"
        let details: [String: Any] = [NSLocalizedDescriptionKey: marker, NSFilePathErrorKey: "/synthetic/" + marker,
                                     NSURLErrorKey: URL(fileURLWithPath: "/synthetic/" + marker)]
        let unknown = ImportSafeFailure(NSError(domain: marker, code: -17, userInfo: details))
        #expect(unknown.domain == .other && unknown.code == -17)
        #expect(!unknown.summary.contains(marker))
        let cocoa = ImportSafeFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: details))
        #expect(cocoa.domain == .cocoa && cocoa.code == NSFileReadNoPermissionError)
        #expect(!cocoa.summary.contains(marker))
        let id = UUID()
        var state = ImportDiagnosticState()
        state.begin(id)
        let acceptedUnknownDomainFailure = state.pickerFailed(NSError(domain: marker, code: NSUserCancelledError, userInfo: details), for: id)
        #expect(acceptedUnknownDomainFailure)
        #expect(state.callback == .failed) // A matching numeric code in an unknown domain is not cancellation.
        #expect(state.failure?.kind == .external)
        state.begin(id)
        let acceptedCancellationFailure = state.pickerFailed(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: details), for: id)
        #expect(acceptedCancellationFailure)
        #expect(state.callback == .cancelled)
        state.begin(id)
        let acceptedForReadFailure = state.selected(for: id, hasFile: true)
        #expect(acceptedForReadFailure)
        state.record(.sourceMetadataStarted, for: id)
        state.fail(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: details), for: id)
        state.record(.alertRequested, for: id)
        #expect(state.failedAfter == .sourceMetadataStarted)
        #expect(state.failure == cocoa)
        #expect(ImportSafeFailure(TXTError.malformedInput(encoding: .utf8, byteOffset: RawByteOffset(42))).kind == .damaged)
    }

    @Test func observedImportDeliversOrderedStagesWithoutChangingOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-diagnostic-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.txt"), bytes = Data("plain synthetic text\nsecond line\n".utf8)
        try bytes.write(to: source)
        let store = try LibraryStore(root: root.appendingPathComponent("Managed"))
        let service = LibraryService(store: store)
        let pair = AsyncStream<ImportStage>.makeStream(bufferingPolicy: .bufferingOldest(32))
        defer { pair.continuation.finish() }
        let consumer = Task {
            var stages: [ImportStage] = []
            for await stage in pair.stream { stages.append(stage) }
            return stages
        }
        let result = try await service.prepareImport(url: source, ticket: UUID(),
            observe: { _ = pair.continuation.yield($0) })
        pair.continuation.finish()
        let stages = await consumer.value
        let expected: [ImportStage] = [.scopeRequested, .sourceMetadataStarted, .sourceMetadataChecked,
            .coordinationStarted, .accessorStarted, .coordinatedMetadataChecked, .copyCompleted, .coordinationFinished,
            .stagedReadStarted, .stagedReadCompleted, .decodingStarted, .decodingCompleted, .committed]
        #expect(stages.filter { $0 != .scopeGranted && $0 != .scopeNotGranted } == expected)
        #expect(stages.filter { $0 == .scopeGranted || $0 == .scopeNotGranted }.count == 1)
        guard case .completed(let receipt) = result else { Issue.record("Expected synthetic import completion"); return }
        #expect(receipt.book.byteCount == bytes.count)
        #expect(try await store.books().count == 1)
        #expect(try Data(contentsOf: source) == bytes)
    }
}
